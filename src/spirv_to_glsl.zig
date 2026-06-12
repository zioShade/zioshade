// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → GLSL cross-compiler backend.
//! Self-contained: includes its own parser, name resolver, and GLSL emitter.
//! Will be deduplicated with spirv_to_hlsl.zig into a shared module later.
const compat = @import("compat.zig");
const std = @import("std");
const spirv = @import("spirv.zig");
const log = std.log.scoped(.spirv_to_glsl);

const common = @import("spirv_cross_common.zig");
const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = struct { decoration: spirv.Decoration, extra: []const u32 };
const CbufferDecl = struct { name: []const u8, type_id: u32, binding: u32 };
const TextureDecl = struct { name: []const u8, binding: u32, is_storage: bool = false, format_str: []const u8 = "rgba8f", dim_str: []const u8 = "2D", is_uint: bool = false, is_int: bool = false, array_size: u32 = 0, arrayed: bool = false };

// ---- Helpers ----
fn getDef(m: *const ParsedModule, id: u32) ?Instruction { if (id >= m.id_defs.len) return null; const i = m.id_defs[id] orelse return null; if (i >= m.instructions.len) return null; return m.instructions[i]; }
fn getTypeOf(m: *const ParsedModule, id: u32) ?u32 { const inst = getDef(m, id) orelse return null; return switch (inst.op) { .TypeVoid,.TypeBool,.TypeInt,.TypeFloat,.TypeVector,.TypeMatrix,.TypeImage,.TypeSampler,.TypeSampledImage,.TypeArray,.TypeRuntimeArray,.TypeStruct,.TypePointer,.TypeFunction => null, else => if (inst.words.len > 1) inst.words[1] else null }; }
fn swizzleChar(i: u32) []const u8 { return switch(i){ 0=>".x",1=>".y",2=>".z",3=>".w",else=>".x"}; }
fn parseLitStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, words.len*4); for(words)|word|{const bytes:[4]u8=@bitCast(word);for(bytes)|c|{if(c==0)break;buf.appendAssumeCapacity(c);}} return buf.toOwnedSlice(alloc); }
fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, name.len); for(name)|c|{switch(c){'a'...'z','A'...'Z','0'...'9','_'=>buf.appendAssumeCapacity(c),else=>buf.appendAssumeCapacity('_'),}} return buf.toOwnedSlice(alloc); }
fn isUniformVar(m: *const ParsedModule, id: u32) bool { const inst = getDef(m, id) orelse return false; if (inst.op == .Variable and inst.words.len >= 4) { const sc: spirv.StorageClass = @enumFromInt(inst.words[3]); return sc == .Uniform; } return false; }

/// A Uniform var whose pointee is a Block-decorated struct (`layout(std140) uniform Foo
/// { ... } foo_1;`). Access lowers to the `{name}_m{idx}` member form. A bare-array
/// Uniform var (`uniform float w[8];`, pointee = TypeArray) is NOT a block — it indexes
/// directly as `w[idx]` and keeps its declaration name in the expression (#289).
/// NOTE: an ARRAYED block (`uniform Foo { ... } foo[N];`, pointee = TypeArray-of-struct)
/// returns false here too — it is left on the direct-index path. That arrays-of-blocks
/// case is KNOWN_UNSUPPORTED (e.g. spv.AofA.frag) and out of scope for #289; this only
/// makes its (already-broken) output differently-shaped, never regresses a passing test.
fn isUniformBlockVar(m: *const ParsedModule, id: u32) bool {
    if (!isUniformVar(m, id)) return false;
    const pt = resolvePointee(m, id) orelse return false;
    const ti = getDef(m, pt) orelse return false;
    if (ti.op != .TypeStruct) return false;
    // An old-style SSBO (`Uniform` storage + `BufferBlock`-decorated struct) is declared as a
    // writable `buffer` block — but ONLY in the compute stage, where the SSBO emission loop
    // runs (it is `is_compute`-gated, matching #296's `.length()` gate). There it keeps its
    // original member names + `{instance}.{member}` access, so it must NOT take the cbuffer
    // `{name}_1.{name}_m{idx}` form. Outside compute it is still emitted via the uniform-block
    // path, so keep treating it as a UBO there to avoid referencing an undeclared block. (#296)
    if (m.execution_model == .GLCompute and structHasBufferBlock(m, pt)) return false;
    return true;
}

/// True if struct type `struct_id` carries the `BufferBlock` decoration. glslangValidator
/// encodes a pre-SPIR-V-1.3 SSBO as a `Uniform`-storage variable whose STRUCT TYPE (not the
/// variable) is decorated `BufferBlock`. Checking the variable id — as the SSBO detection
/// did before — never matched, so glslang SSBOs were misrouted to the read-only `uniform`
/// cbuffer path. The decoration is an `OpDecorate` (not `OpMemberDecorate`) on the type.
fn structHasBufferBlock(m: *const ParsedModule, struct_id: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3 and inst.words[1] == struct_id) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            if (dec == .buffer_block) return true;
        }
    }
    return false;
}

/// True if `id` is an old-style SSBO variable: `Uniform` storage class whose pointee struct
/// type carries `BufferBlock` (glslangValidator's SSBO encoding). glslpp's own frontend uses
/// the `StorageBuffer` storage class instead, so this only catches glslang-produced SPIR-V.
fn isOldStyleSSBOVar(m: *const ParsedModule, id: u32) bool {
    if (!isUniformVar(m, id)) return false;
    const pt = resolvePointee(m, id) orelse return false;
    return structHasBufferBlock(m, pt);
}

/// True if `id` is an SSBO variable declared as an ANONYMOUS block — its instance name is
/// empty (glslangValidator emits an empty `OpName` for `buffer B { ... };`). An anonymous
/// block exposes its members directly in global scope, so member access must be BARE (`a`),
/// never `{instance}.a` — and crucially never the leading-dot `.a` produced when the empty
/// instance name is prefixed. glslang rejects `.a` with "unexpected DOT". Mirrors the
/// gl_PerVertex builtin-block base suppression (isBuiltinBlockVar). Compute-gated to match
/// the SSBO emission loop and isUniformBlockVar's BufferBlock exclusion: only there is the
/// block actually emitted anonymously; elsewhere it routes through the named cbuffer path.
fn isAnonymousSSBOVar(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32) bool {
    if (m.execution_model != .GLCompute) return false;
    const def = getDef(m, id) orelse return false;
    if (def.op != .Variable or def.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(def.words[3]);
    if (sc != .StorageBuffer and !isOldStyleSSBOVar(m, id)) return false;
    const nm = names.get(id) orelse return true; // absent OpName ⇒ anonymous
    return nm.len == 0;
}

fn resolvePointee(m: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(m, id) orelse return null;
    switch(inst.op) {
        .Variable => { const pt = getDef(m, inst.words[1]) orelse return null; if (pt.op == .TypePointer and pt.words.len > 3) return pt.words[3]; return null; },
        .AccessChain => {
            var cur = resolvePointee(m, inst.words[3]);
            for (inst.words[4..]) |idx_id| {
                const idx_def = getDef(m, idx_id);
                if (cur) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur = tinst.words[2];
                        } else if (tinst.op == .TypeStruct) {
                            if (idx_def) |d| {
                                if (d.op == .Constant and d.words.len > 3) {
                                    const v = d.words[3];
                                    if (v + 2 < tinst.words.len) { cur = tinst.words[v + 2]; } else cur = null;
                                }
                            }
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                            cur = tinst.words[2];
                        } else {
                            cur = null;
                        }
                    } else {
                        cur = null;
                    }
                } else {
                    cur = null;
                }
            }
            return cur;
        },
        else => return null,
    }
}

fn exprName(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32, alloc: std.mem.Allocator) []const u8 {
    if (names.get(id)) |n| return n;
    const def = getDef(m, id) orelse return std.fmt.allocPrint(alloc, "v{d}", .{id}) catch "?";
    if (def.op == .ConstantTrue) return "true";
    if (def.op == .ConstantFalse) return "false";
    return std.fmt.allocPrint(alloc, "v{d}", .{id}) catch "?";
}

/// Look up the BuiltIn decoration (if any) on member `member_idx` of struct type
/// `struct_id`. gl_PerVertex and similar interface blocks carry BuiltIn on the
/// *members* via `OpMemberDecorate` — which the `decs` map (OpDecorate-only) does
/// not capture — so this scans the member decorations directly.
fn structMemberBuiltin(m: *const ParsedModule, struct_id: u32, member_idx: u32) ?spirv.BuiltIn {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 5 and
            inst.words[1] == struct_id and inst.words[2] == member_idx)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .built_in) return @enumFromInt(inst.words[4]);
        }
    }
    return null;
}

/// True when `struct_id` is a built-in interface block (e.g. gl_PerVertex): a
/// struct with at least one member carrying a BuiltIn decoration.
fn isBuiltinBlockType(m: *const ParsedModule, struct_id: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 5 and inst.words[1] == struct_id) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .built_in) return true;
        }
    }
    return false;
}

/// True when `var_id` is a variable whose pointee type is a built-in interface
/// block (gl_PerVertex). Such variables must NOT be declared as `out`/`in`
/// varyings — their members (gl_Position, …) are predefined in GLSL — and member
/// access through them must lower to the bare gl_* name (no block instance prefix).
fn isBuiltinBlockVar(m: *const ParsedModule, var_id: u32) bool {
    const pointee = resolvePointee(m, var_id) orelse return false;
    return isBuiltinBlockType(m, pointee);
}

/// Map a gl_PerVertex-style BuiltIn member to its predefined GLSL name. Returns
/// null for builtins glslpp doesn't lower to a bare gl_* (caller falls back to the
/// OpMemberName, which glslang also names gl_*).
fn builtinBlockMemberName(bi: spirv.BuiltIn) ?[]const u8 {
    return switch (bi) {
        .position => "gl_Position",
        .point_size => "gl_PointSize",
        .clip_distance => "gl_ClipDistance",
        .cull_distance => "gl_CullDistance",
        else => null,
    };
}

fn buildAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) return try alloc.dupe(u8, base_name);
    // A bare-array Uniform var is NOT a block: keep its name in the expression and
    // index directly (`w[2]`), not the `{name}_m{idx}` block-member form (#289).
    const base_is_cb = isUniformBlockVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    // A gl_PerVertex-style built-in block: emit no base instance — its members
    // lower to bare gl_* names (handled per-index below), matching spirv-cross.
    const base_is_builtin_block = isBuiltinBlockVar(m, base_id);
    // An anonymous SSBO block: suppress the (empty) instance base and emit the first
    // member level bare (`a`), never `.a` — glslang rejects the leading dot. (#304 follow-up)
    const base_is_anon = isAnonymousSSBOVar(m, names, base_id);
    // Use a stack buffer to avoid heap allocation for typical access chains
    var writer = compat.StackBufWriter(512).init();
    if (!base_is_cb and !base_is_builtin_block and !base_is_anon) writer.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    var cb_level: bool = base_is_cb; // only first level uses cb_prefix
    var anon_level: bool = base_is_anon; // only first member level drops the dot
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_struct_member = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeStruct; } else false;
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    writer.writeAll(swizzleChar(val));
                } else if (cb_level and base_is_cb) {
                    writer.print("{s}_m{d}", .{cb_prefix, val});
                    cb_level = false; // only first index uses cb_prefix
                } else if (is_struct_member) {
                    if (structMemberBuiltin(m, cur_type.?, val)) |bi| {
                        var mname_buf: [32]u8 = undefined;
                        const gn = builtinBlockMemberName(bi) orelse getMemberName(m, cur_type.?, val, &mname_buf);
                        // Bare gl_* only when the block instance base was suppressed
                        // (gl_PerVertex). For an array-of-block element such as
                        // gl_in[i].gl_Position the base is kept, so keep the dot.
                        if (base_is_builtin_block) writer.writeAll(gn) else writer.print(".{s}", .{gn});
                    } else {
                        // Use struct member name for nested struct access
                        var mname_buf: [32]u8 = undefined;
                        const mname = getMemberName(m, cur_type.?, val, &mname_buf);
                        if (anon_level) { writer.writeAll(mname); anon_level = false; } else writer.print(".{s}", .{mname});
                    }
                } else {
                    writer.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else { writer.print("[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { writer.print("[{s}]", .{names.get(index_id) orelse "i"}); }
    }
    if (!writer.overflowed()) {
        const result = try alloc.dupe(u8, writer.written());
        return result;
    }
    // Fallback to heap allocation for long chains
    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    if (!base_is_cb and !base_is_builtin_block and !base_is_anon) try buf.appendSlice(alloc, base_name);
    cur_type = resolvePointee(m, base_id);
    var cb_level2: bool = base_is_cb;
    var anon_level2: bool = base_is_anon;
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_struct_member = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeStruct; } else false;
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try buf.appendSlice(alloc, swizzleChar(val));
                } else if (cb_level2 and base_is_cb) {
                    try buf.print(alloc, "{s}_m{d}", .{cb_prefix, val});
                    cb_level2 = false;
                } else if (is_struct_member) {
                    if (structMemberBuiltin(m, cur_type.?, val)) |bi| {
                        var mname_buf: [32]u8 = undefined;
                        const gn = builtinBlockMemberName(bi) orelse getMemberName(m, cur_type.?, val, &mname_buf);
                        if (base_is_builtin_block) try buf.appendSlice(alloc, gn) else try buf.print(alloc, ".{s}", .{gn});
                    } else {
                        var mname_buf: [32]u8 = undefined;
                        const mname = getMemberName(m, cur_type.?, val, &mname_buf);
                        if (anon_level2) { try buf.appendSlice(alloc, mname); anon_level2 = false; } else try buf.print(alloc, ".{s}", .{mname});
                    }
                } else {
                    try buf.print(alloc, "[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                        else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            } else { try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"}); }
    }
    return buf.toOwnedSlice(alloc);
}

fn writeResolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, w: anytype) !void {
    const inst = getDef(m, ptr_id) orelse { try w.writeAll(names.get(ptr_id) orelse "var"); return; };
    if (inst.op == .AccessChain) {
        try writeAccessExpr(m, names, inst.words[3], inst.words[4..], w);
        return;
    }
    try w.writeAll(names.get(ptr_id) orelse "var");
}

fn writeAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) { try w.writeAll(base_name); return; }
    // Bare-array Uniform vars are not blocks — index directly (`w[2]`), #289.
    const base_is_cb = isUniformBlockVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    const base_is_builtin_block = isBuiltinBlockVar(m, base_id);
    const base_is_anon = isAnonymousSSBOVar(m, names, base_id);
    if (!base_is_cb and !base_is_builtin_block and !base_is_anon) try w.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    var cb_level: bool = base_is_cb;
    var anon_level: bool = base_is_anon;
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_struct_member = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeStruct; } else false;
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else if (cb_level and base_is_cb) {
                    // GLSL: use instance.member format — instance is "{cb_prefix}_1", member is "{cb_prefix}_m{val}"
                    try w.print("{s}_1.{s}_m{d}", .{cb_prefix, cb_prefix, val});
                    cb_level = false;
                } else if (is_struct_member) {
                    if (structMemberBuiltin(m, cur_type.?, val)) |bi| {
                        var mname_buf: [32]u8 = undefined;
                        const gn = builtinBlockMemberName(bi) orelse getMemberName(m, cur_type.?, val, &mname_buf);
                        // Bare gl_* only when the block instance base was suppressed
                        // (gl_PerVertex). For an array-of-block element such as
                        // gl_in[i].gl_Position the base is kept, so keep the dot.
                        if (base_is_builtin_block) try w.writeAll(gn) else try w.print(".{s}", .{gn});
                    } else {
                        var mname_buf: [32]u8 = undefined;
                        const mname = getMemberName(m, cur_type.?, val, &mname_buf);
                        if (anon_level) { try w.writeAll(mname); anon_level = false; } else try w.print(".{s}", .{mname});
                    }
                } else {
                    try w.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                        else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            } else { try w.print("[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { try w.print("[{s}]", .{names.get(index_id) orelse "i"}); }
    }
}

fn resolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, ptr_id) orelse { const n = names.get(ptr_id) orelse "var"; return try alloc.dupe(u8, n); };
    if (inst.op == .AccessChain) return try buildAccessExpr(m, names, inst.words[3], inst.words[4..], alloc);
    const n = names.get(ptr_id) orelse "var";
    return try alloc.dupe(u8, n);
}

// ---- GLSL type resolution ----
fn getArraySuffix(m: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    // multi_dim=true: a local/output variable of a multi-dimensional array type
    // (`vec4 v[2][2]`) must emit ALL nested dimensions. With single-dim, a 2D
    // array local was declared `vec4 v[2];` then assigned a `vec4 v[2][2]`
    // const — glslang rejects the type mismatch (GLSL 4.30+ supports arrays of
    // arrays; spirv-cross also emits the full `[N][M]`).
    return common.commonGetArraySuffix(m.instructions, m.id_defs, ptr_type_id, true);
}

fn glslType(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, type_id) orelse return "vec4";
    return switch (inst.op) {
        .TypeVoid => "void",
        .TypeBool => "bool",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeFloat => if (inst.words.len > 2 and inst.words[2] == 16) "float16_t" else "float",
        .TypeVector => {
            const s = try glslType(m, inst.words[2], names, alloc);
            const c = inst.words[3];
            if (std.mem.eql(u8,s,"float")) { if(c>=1 and c<=4) return ([_][]const u8{"","float","vec2","vec3","vec4"})[c]; }
            else if (std.mem.eql(u8,s,"float16_t")) { if(c>=1 and c<=4) return ([_][]const u8{"","float16_t","f16vec2","f16vec3","f16vec4"})[c]; }
            else if (std.mem.eql(u8,s,"int")) { if(c>=1 and c<=4) return ([_][]const u8{"","int","ivec2","ivec3","ivec4"})[c]; }
            else if (std.mem.eql(u8,s,"uint")) { if(c>=1 and c<=4) return ([_][]const u8{"","uint","uvec2","uvec3","uvec4"})[c]; }
            else if (std.mem.eql(u8,s,"bool")) { if(c>=1 and c<=4) return ([_][]const u8{"","bool","bvec2","bvec3","bvec4"})[c]; }
            return std.fmt.allocPrint(alloc, "{s}{d}", .{s, c});
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const ct = getDef(m, inst.words[2]);
            const rows: u32 = if (ct) |c| c.words[3] else cols;
            if (cols == rows and cols >= 2 and cols <= 4) return ([_][]const u8{"","","mat2","mat3","mat4"})[cols];
            return std.fmt.allocPrint(alloc, "mat{d}x{d}", .{cols, rows});
        },
        .TypeArray, .TypeRuntimeArray => try glslType(m, inst.words[2], names, alloc),
        .TypePointer => if (inst.words.len > 3) try glslType(m, inst.words[3], names, alloc) else "vec4",
        .TypeStruct => names.get(type_id) orelse "Struct",
        else => "vec4",
    };
}

/// Loop-header OpPhi (the loop counter): materialized as a mutable variable so
/// the counter is not frozen at its constant init value (#phi-loop). Mirrors the
/// HLSL backend's fix (src/spirv_to_hlsl.zig).
const PhiInfo = struct { result_id: u32, type_id: u32, init_id: u32, update_id: u32 };

// Per-emitBody loop-phi state. Set at the start of emitBody and read by
// emitWhileLoop and emitBlock — avoids threading three maps through emitBlock's
// 19 call sites. Safe: read only within the synchronous extent of one emitBody
// (threadlocal guards against any parallel backend invocation).
threadlocal var g_loop_phis: ?*const std.AutoHashMap(usize, std.ArrayList(PhiInfo)) = null;
threadlocal var g_phi_hdr: ?*const std.AutoHashMap(u32, usize) = null;
threadlocal var g_deferred_hdr: ?*const std.AutoHashMap(usize, void) = null;

/// GLSL type name for a loop-phi variable declaration — STATIC strings only (no
/// allocation), for the scalar/vector types loop phis realistically carry.
fn phiTypeNameGLSL(m: *const ParsedModule, type_id: u32) []const u8 {
    const tinst = getDef(m, type_id) orelse return "int";
    switch (tinst.op) {
        .TypeBool => return "bool",
        .TypeInt => return if (tinst.words.len > 3 and tinst.words[3] != 0) "int" else "uint",
        .TypeFloat => return if (tinst.words.len > 2 and tinst.words[2] == 16) "float16_t" else "float",
        .TypeVector => {
            const s = phiTypeNameGLSL(m, tinst.words[2]);
            const c = tinst.words[3];
            if (c < 1 or c > 4) return "int";
            const i: usize = c;
            if (std.mem.eql(u8, s, "float")) return ([_][]const u8{ "", "float", "vec2", "vec3", "vec4" })[i];
            if (std.mem.eql(u8, s, "float16_t")) return ([_][]const u8{ "", "float16_t", "f16vec2", "f16vec3", "f16vec4" })[i];
            if (std.mem.eql(u8, s, "int")) return ([_][]const u8{ "", "int", "ivec2", "ivec3", "ivec4" })[i];
            if (std.mem.eql(u8, s, "uint")) return ([_][]const u8{ "", "uint", "uvec2", "uvec3", "uvec4" })[i];
            if (std.mem.eql(u8, s, "bool")) return ([_][]const u8{ "", "bool", "bvec2", "bvec3", "bvec4" })[i];
            return "int";
        },
        else => return "int",
    }
}

/// If `inst` is a loop-header phi, emit its mutable-variable declaration
/// (`TYPE name = <init>;`) at `indent` and return true (caller should `continue`).
fn tryEmitLoopPhiDeclGLSL(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator, indent: []const u8) !bool {
    if (inst.op != .Phi) return false;
    const ph = g_phi_hdr orelse return false;
    const lmi = ph.get(inst.words[2]) orelse return false;
    const lp = g_loop_phis orelse return false;
    const plist = lp.get(lmi) orelse return false;
    for (plist.items) |pi| {
        if (pi.result_id != inst.words[2]) continue;
        const tyname = phiTypeNameGLSL(m, pi.type_id);
        if (names.get(pi.result_id) == null) {
            const nm = std.fmt.allocPrint(alloc, "v{d}", .{pi.result_id}) catch "vphi";
            if (names.fetchPut(pi.result_id, nm) catch null) |old| alloc.free(old.value);
        }
        const vname = names.get(pi.result_id) orelse "vphi";
        const init_name = names.get(pi.init_id) orelse "0";
        try w.print("{s}{s} {s} = {s};\n", .{ indent, tyname, vname, init_name });
    }
    return true;
}

fn isDeferredHdrGLSL(idx: usize) bool {
    const dh = g_deferred_hdr orelse return false;
    return dh.contains(idx);
}

fn tryResolveTypeName(m: *const ParsedModule, type_id: u32) []const u8 {
    const inst = getDef(m, type_id) orelse return "float";
    return switch(inst.op){ .TypeFloat=>"float", .TypeInt=>if(inst.words.len>3 and inst.words[3]!=0)"int" else "uint", .TypeBool=>"bool", else=>"float" };
}

fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    if (type_inst.op == .TypeFloat and literal_words.len > 0) {
        const val: f32 = @bitCast(literal_words[0]);
        if (val == @floor(val) and @abs(val) < 1e6) { const ival: i32 = @intFromFloat(val); return std.fmt.allocPrint(alloc, "{d}.0", .{ival}); }
        return std.fmt.allocPrint(alloc, "{d}", .{val});
    }
    if (type_inst.op == .TypeInt and literal_words.len > 0) {
        const signed = type_inst.words.len > 3 and type_inst.words[3] != 0;
        if (signed) { const val: i32 = @bitCast(literal_words[0]); return std.fmt.allocPrint(alloc, "{d}", .{val}); }
        else return std.fmt.allocPrint(alloc, "{d}u", .{literal_words[0]});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{literal_words[0]});
}

fn getDecVal(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decs.get(id) orelse return null;
    for (list.items) |e| { if (e.decoration == dec and e.extra.len > 0) return e.extra[0]; }
    return null;
}

fn hasDec(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) bool {
    const list = decs.get(id) orelse return false;
    for (list.items) |e| { if (e.decoration == dec) return true; }
    return false;
}

// ---- Public API ----
/// Options for SPIR-V → GLSL cross-compilation.
pub const GlslCompileOptions = struct {
    /// Target GLSL version. Must be one of `supported_glsl_versions`
    /// (330, 400, 410, 420, 430, 440, 450, 460); anything else is rejected with
    /// `error.UnsupportedGlslVersion`. ESSL is excluded (#169).
    version: u32 = 430,
    /// Output OpenGL ES Shading Language (ESSL) instead of desktop GLSL.
    es: bool = false,
    /// Entry point name to compile (default: "main").
    entry_point_name: []const u8 = "main",
    /// Shift all descriptor bindings by this amount. -1 remaps binding=1 → binding=0.
    /// Negative results clamp to 0. Mirrors `HlslCompileOptions.binding_shift`.
    binding_shift: i32 = 0,
};

// Use shared parse cache from root (avoids circular import — cache is passed via allocator context)
/// Single source of truth for the desktop GLSL versions glslpp can emit. ESSL is
/// intentionally excluded (#169). Referenced by both the honest-error gate and the
/// `GlslCompileOptions.version` doc comment so the two cannot drift apart.
pub const supported_glsl_versions = [_]u32{ 330, 400, 410, 420, 430, 440, 450, 460 };

fn isSupportedGlslVersion(v: u32) bool {
    for (supported_glsl_versions) |sv| {
        if (v == sv) return true;
    }
    return false;
}

/// `layout(location=)` on a *varying* (fragment input / vertex output) is rejected
/// by glslang below 410; vertex inputs (attributes) and fragment outputs always keep
/// it. spirv-cross drops it the same way. (#169 BLOCKER 1: this is < 410, not == 330
/// — explicit varying locations are not core GLSL until 410, so 400 must also drop.)
fn dropVaryingLocation(version: u32, model: spirv.ExecutionModel, comptime dir: enum { in, out }) bool {
    return version < 410 and switch (dir) {
        .in => model == .Fragment,
        .out => model == .Vertex,
    };
}

pub fn spirvToGLSL(alloc: std.mem.Allocator, spirv_words: []const u32, options: GlslCompileOptions) ![]const u8 {
    // #169 (G4): honest-error before doing any work. ESSL is out of scope; the
    // `es` field must not be silently ignored. Only the supported desktop set is
    // accepted — anything else is a hard error rather than an invalid #version.
    if (options.es) return error.EsslUnsupported;
    if (!isSupportedGlslVersion(options.version)) return error.UnsupportedGlslVersion;

    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V. No-op
    // (byte-identical copy) on already-structured input; on failure fall back to
    // the original words so the backend's own honest-error path is unchanged.
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words) catch null;
    defer if (_norm) |n| alloc.free(n);
    var module = try parseModule(alloc, _norm orelse spirv_words);
    defer module.deinit(alloc);

    // Override entry point if requested
    if (!std.mem.eql(u8, options.entry_point_name, "main")) {
        if (findEntryPoint(&module, options.entry_point_name)) |ep_id| {
            module.entry_point_id = ep_id;
        } else return error.EntryPointNotFound;
    }

    // Mesh/task shaders cannot be cross-compiled to GLSL (no standard dialect exists)
    if (module.execution_model == .MeshEXT or module.execution_model == .TaskEXT or
        module.execution_model == .RayGenerationKHR or module.execution_model == .IntersectionKHR or
        module.execution_model == .AnyHitKHR or module.execution_model == .ClosestHitKHR or
        module.execution_model == .MissKHR or module.execution_model == .CallableKHR) {
        return error.CrossCompileUnsupported;
    }

    const entry_id = module.entry_point_id orelse return error.NoEntryPoint;

    // Arena allocator for all backend internals — eliminates individual free() overhead
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = std.AutoHashMap(u32, []const u8).init(aa);
    defer names.deinit();
    var decs = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(aa);
    defer decs.deinit();

    collectNames(aa, &module, &names);
    // Alias const-initialised Private globals to their promoted const literal
    // (the array ConstantComposite is already declared as a global `const`), so
    // `arr[i]` resolves to the literal instead of an undeclared variable (Design A).
    common.aliasConstInitializedPrivateVars(aa, &module, &names);
    try collectDecorations(aa, &module, &decs);

    var cbuffers = std.ArrayList(CbufferDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer cbuffers.deinit(aa);
    var textures = std.ArrayList(TextureDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer textures.deinit(aa);
    collectResources(&module, &names, &decs, &cbuffers, &textures, aa);

    var output = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    var output_owned = true;
    defer if (output_owned) output.deinit(alloc);
    const w = compat.listWriter(&output, alloc);

    const is_compute = module.execution_model == .GLCompute;

    try w.print("#version {d}\n", .{options.version});

    // #169 (G4) Tier 2: at versions < 420, `layout(binding=)` on UBOs/samplers is
    // only legal with GL_ARB_shading_language_420pack. glslang predefines this
    // extension at 330/410, so guarding it makes our binding= output validate.
    // Emit the guard verbatim (matches spirv-cross at versions <= 410).
    if (options.version < 420) {
        try w.writeAll(
            \\#ifdef GL_ARB_shading_language_420pack
            \\#extension GL_ARB_shading_language_420pack : require
            \\#endif
            \\
        );
    }
    try w.writeAll("\n");

    // For compute shaders: emit local_size and SSBO declarations
    if (is_compute) {
        const ls = module.local_size;
        try w.print("layout(local_size_x = {d}, local_size_y = {d}, local_size_z = {d}) in;\n\n", .{ls[0], ls[1], ls[2]});
    }

    // Emit struct forward declarations for types used in UBOs
    var emitted_structs = std.AutoHashMap(u32, void).init(aa);
    defer emitted_structs.deinit();
    var emitted_names = std.StringHashMap(void).init(aa);
    defer emitted_names.deinit();
    for (cbuffers.items) |cb| {
        emitStructForwardDecls(&module, &names, cb.type_id, w, aa, &emitted_structs, &emitted_names) catch {};
    }

    for (cbuffers.items) |cb| {
        // A plain non-opaque global uniform (`uniform int n;` — a default-uniform-block
        // member glslpp supports as a desktop-GLSL extension) is a BARE scalar/vector/
        // matrix Uniform var, not a Block-decorated struct. Emit it as a plain
        // `uniform TYPE name;` (#286) — the body references the var name directly — rather
        // than an empty `uniform name {} name_1;` block that drops the value.
        // Bare ARRAY uniforms (`uniform float w[8];` — an OpTypeArray pointee, not a
        // Block struct) emit `uniform {elem} {name}[{N}];` with the dimension preserved
        // (glslType drops it); the body indexes them directly as `w[2]` (handled in the
        // access path by the `base_is_cb` + pointee-is-struct guard, since these are NOT
        // block members) — #289.
        const cbt = getDef(&module, cb.type_id);
        const is_struct = cbt != null and cbt.?.op == .TypeStruct;
        const is_array = cbt != null and (cbt.?.op == .TypeArray or cbt.?.op == .TypeRuntimeArray);
        if (!is_struct) {
            if (is_array) {
                // Walk nested TypeArray layers to emit EVERY dimension — glslType
                // strips them (`float w[2][3]` would degrade to `uniform float w[2];`
                // and mismatch the `w[1][2]` use). RuntimeArray (no length) emits `[]`.
                var dims = std.ArrayList([]const u8).initCapacity(aa, 2) catch return error.OutOfMemory;
                var elem_id: u32 = cb.type_id;
                while (getDef(&module, elem_id)) |inn| {
                    if (inn.op == .TypeArray and inn.words.len > 3) {
                        const len_def = getDef(&module, inn.words[3]);
                        const len_val: u32 = if (len_def) |ld| (if (ld.words.len > 3) ld.words[3] else 1) else 1;
                        dims.append(aa, std.fmt.allocPrint(aa, "[{d}]", .{len_val}) catch "[1]") catch {};
                        elem_id = inn.words[2];
                    } else if (inn.op == .TypeRuntimeArray and inn.words.len > 2) {
                        dims.append(aa, "[]") catch {};
                        elem_id = inn.words[2];
                    } else break;
                }
                const elem_tn = glslType(&module, elem_id, &names, aa) catch return error.OutOfMemory;
                try w.print("uniform {s} {s}", .{ elem_tn, cb.name });
                for (dims.items) |d| try w.writeAll(d);
                try w.writeAll(";\n\n");
            } else {
                const tn = glslType(&module, cb.type_id, &names, aa) catch return error.OutOfMemory;
                try w.print("uniform {s} {s};\n\n", .{ tn, cb.name });
            }
            continue;
        }
        const shifted = common.applyBindingShift(cb.binding, options.binding_shift);
        try w.print("layout(binding = {d}, std140) uniform {s}\n{{\n", .{shifted, cb.name});
        try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa, false);
        try w.print("}} {s}_1;\n\n", .{cb.name});
    }

    // For compute shaders: emit SSBO (storage buffer) declarations
    if (is_compute) {
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                // SSBOs use StorageBuffer storage class (SPIR-V 1.3+) or, from glslangValidator,
                // Uniform storage + a BufferBlock-decorated STRUCT TYPE. The BufferBlock decoration
                // sits on the struct type, not the variable, so detect it via the pointee (#296).
                const is_old_style = isOldStyleSSBOVar(&module, inst.words[2]);
                const is_ssbo = sc == .StorageBuffer or is_old_style;
                if (!is_ssbo) continue;
                const rid = inst.words[2];
                const binding = getDecVal(&decs, rid, .binding) orelse continue;
                const shifted_binding = common.applyBindingShift(binding, options.binding_shift);
                const name = names.get(rid) orelse continue;
                // The block TYPE tag must differ from the INSTANCE name (`name`), or glslang
                // rejects `buffer B { ... } B;` with "block instance name redefinition". The
                // body accesses members as `{name}.{member}`, so the instance stays `name`;
                // the type gets a distinct `{name}_block` tag (the tag is never referenced).
                const block_tag = std.fmt.allocPrint(aa, "{s}_block", .{name}) catch return error.OutOfMemory;
                try w.print("layout(std430, binding = {d}) buffer {s}\n{{\n", .{shifted_binding, block_tag});
                // Emit struct members by their ORIGINAL names (`b.lock`) for BOTH SSBO
                // encodings: StorageBuffer-class and old-style Uniform+BufferBlock now both
                // bypass isUniformBlockVar (see structHasBufferBlock there), so the body
                // accesses members as `{instance}.{member}` — declare them to match. (#296)
                const use_original = true;
                const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
                if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                    try emitStructMembers(&module, &names, ptr_inst.words[3], name, w, aa, use_original);
                }
                try w.print("}} {s};\n\n", .{name});
            }
        }
    }
    for (textures.items) |tex| {
        const tex_shifted = common.applyBindingShift(tex.binding, options.binding_shift);
        // Descriptor-array suffix, e.g. `[4]` for `uniform sampler2D tex[4]`.
        const arr: []const u8 = if (tex.array_size > 0) (std.fmt.allocPrint(aa, "[{d}]", .{tex.array_size}) catch "") else "";
        // Arrayed-image suffix appended to the GLSL dimension spelling
        // (`2D`→`2DArray`, `Cube`→`CubeArray`, `1D`→`1DArray`). The OpTypeImage
        // `Arrayed` operand drove this; without it `sampler2DArray` degraded to
        // `sampler2D`. GLSL keeps the layer in the sample coord, so no call change.
        const dim_str: []const u8 = if (tex.arrayed) (std.fmt.allocPrint(aa, "{s}Array", .{tex.dim_str}) catch tex.dim_str) else tex.dim_str;
        if (tex.is_storage) {
            const itype = if (std.mem.eql(u8, dim_str, "Buffer")) (if (tex.is_uint) "uimageBuffer" else if (tex.is_int) "iimageBuffer" else "imageBuffer") else std.fmt.allocPrint(aa, "{s}image{s}", .{if (tex.is_uint) "u" else if (tex.is_int) "i" else "", dim_str}) catch "image2D";
            try w.print("layout(binding = {d}, {s}) uniform {s} {s}{s};\n", .{tex_shifted, tex.format_str, itype, tex.name, arr});
        } else {
            const stype = if (tex.is_uint) std.fmt.allocPrint(aa, "usampler{s}", .{dim_str}) catch "usampler2D" else if (tex.is_int) std.fmt.allocPrint(aa, "isampler{s}", .{dim_str}) catch "isampler2D" else if (std.mem.eql(u8, dim_str, "2D")) "sampler2D" else std.fmt.allocPrint(aa, "sampler{s}", .{dim_str}) catch "sampler2D";
            try w.print("layout(binding = {d}) uniform {s} {s}{s};\n", .{tex_shifted, stype, tex.name, arr});
        }
    }
    if (textures.items.len > 0) try w.writeAll("\n");

    // Emit specialization constants as layout(constant_id = N) const declarations.
    // Per-scalar OpSpecConstants get one declaration; the OpSpecConstantComposite
    // gets a `const vecN <name> = vecN(c0, c1, ...);` declaration referencing the
    // scalar names (no constant_id — that lives on the scalars). Override the
    // scalars via SpecId, the composite recomputes at pipeline time.
    for (module.instructions) |inst| {
        const is_scalar_sc = inst.op == .SpecConstant and inst.words.len > 3;
        const is_bool_sc = (inst.op == .SpecConstantTrue or inst.op == .SpecConstantFalse) and inst.words.len > 2;
        if (!is_scalar_sc and !is_bool_sc) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try glslType(&module, type_id, &names, aa);
        // Find SpecId decoration
        const spec_id: ?u32 = blk: {
            const dec_list = decs.get(result_id) orelse break :blk null;
            for (dec_list.items) |d| {
                if (d.decoration == .spec_id and d.extra.len > 0) break :blk d.extra[0];
            }
            break :blk null;
        };
        const sid = spec_id orelse continue;
        if (is_bool_sc) {
            const bool_val: []const u8 = if (inst.op == .SpecConstantTrue) "true" else "false";
            try w.print("layout(constant_id = {d}) const bool {s} = {s};\n", .{ sid, name, bool_val });
        } else {
            const default_val = inst.words[3];
            if (std.mem.eql(u8, type_str, "float")) {
                const fv: f32 = @bitCast(default_val);
                try w.print("layout(constant_id = {d}) const {s} {s} = {d};\n", .{ sid, type_str, name, fv });
            } else {
                try w.print("layout(constant_id = {d}) const {s} {s} = {d};\n", .{ sid, type_str, name, default_val });
            }
        }
    }
    // OpSpecConstantComposite: emit `const vecN <name> = vecN(c0, c1, ...);` —
    // no constant_id on the composite (the SpecIds live on the per-scalar
    // OpSpecConstants); the composite is rebuilt at pipeline time from the
    // (possibly overridden) scalars.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantComposite or inst.words.len <= 3) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try glslType(&module, type_id, &names, aa);
        const constituents = inst.words[3..];
        try w.print("const {s} {s} = {s}(", .{ type_str, name, type_str });
        for (constituents, 0..) |c_id, i| {
            if (i > 0) try w.writeAll(", ");
            const c_name = names.get(c_id) orelse "0";
            try w.writeAll(c_name);
        }
        try w.writeAll(");\n");
    }
    // M3.5: emit OpSpecConstantOp instructions as derived const expressions.
    // GLSL natively supports `const int X = SPEC * 2;` over a spec const;
    // pipeline tooling re-evaluates the expression when the leaf is overridden.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantOp or inst.words.len < 6) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try glslType(&module, type_id, &names, aa);
        const op_str: ?[]const u8 = switch (opcode_lit) {
            128, 129 => @as([]const u8, "+"), // IAdd / FAdd
            130, 131 => @as([]const u8, "-"), // ISub / FSub
            132, 133 => @as([]const u8, "*"), // IMul / FMul
            134, 135, 136 => @as([]const u8, "/"), // UDiv / SDiv / FDiv
            else => null,
        };
        const op = op_str orelse continue;
        // Binary form only (v1): wc == 6 (header + type_id + result_id + opcode + op0 + op1)
        if (inst.words.len != 6) continue;
        const op0 = names.get(inst.words[4]) orelse continue;
        const op1 = names.get(inst.words[5]) orelse continue;
        try w.print("const {s} {s} = {s} {s} {s};\n", .{ type_str, name, op0, op, op1 });
    }
    try w.writeAll("\n");

    // Emit constant array/struct composites as const declarations
    // Also scan for struct types used in composites for forward declarations
    for (module.instructions) |inst| {
        if (inst.op != .ConstantComposite or inst.words.len <= 3) continue;
        const rid = inst.words[2];
        const type_id = inst.words[1];
        const type_inst = getDef(&module, type_id) orelse continue;
        if (type_inst.op == .TypeArray) {
            // const elemType name[N][M]... = {comp0, comp1, ...}
            const len_id = type_inst.words[3];
            const len_def = getDef(&module, len_id);
            const len_val: u32 = if (len_def) |ld| ld.words[3] else 1;
            var elem_id = type_inst.words[2];
            var dims = std.ArrayList(u32).initCapacity(aa, 2) catch continue;
            defer dims.deinit(aa);
            dims.append(aa, len_val) catch {};
            // Walk nested TypeArray to find all dimensions
            var inner = getDef(&module, elem_id);
            while (inner) |inn| {
                if (inn.op == .TypeArray and inn.words.len > 3) {
                    const inner_len_id = inn.words[3];
                    const inner_len_def = getDef(&module, inner_len_id);
                    const inner_len: u32 = if (inner_len_def) |ild| ild.words[3] else 1;
                    dims.append(aa, inner_len) catch {};
                    elem_id = inn.words[2];
                    inner = getDef(&module, elem_id);
                } else break;
            }
            const base_type = try glslType(&module, elem_id, &names, aa);
            var arr_suffix = std.ArrayList(u8).initCapacity(aa, 32) catch continue;
            defer arr_suffix.deinit(aa);
            for (dims.items) |d| {
                arr_suffix.print(aa, "[{d}]", .{d}) catch {};
            }
            const name = names.get(rid) orelse continue;
            try w.print("const {s} {s}{s} = {{", .{base_type, name, arr_suffix.items});
            for (inst.words[3..], 0..) |comp_id, i| {
                if (i > 0) try w.writeAll(", ");
                const comp_name = names.get(comp_id) orelse "0";
                try w.writeAll(comp_name);
            }
            try w.writeAll("};\n");
            // Also declare struct type for element type
            const selem_id = type_inst.words[2];
            const elem_inst = getDef(&module, selem_id);
            if (elem_inst) |ei| {
                if (ei.op == .TypeStruct) {
                    emitOneStructForwardDecl(&module, &names, elem_id, w, aa, &emitted_structs, &emitted_names) catch {};
                }
            }
        } else if (type_inst.op == .TypeStruct) {
            // Forward declare the struct first
            emitOneStructForwardDecl(&module, &names, type_id, w, aa, &emitted_structs, &emitted_names) catch {};
            const struct_name = names.get(type_id) orelse "Struct";
            const name = names.get(rid) orelse continue;
            try w.print("const {s} {s} = {{", .{struct_name, name});
            for (inst.words[3..], 0..) |comp_id, i| {
                if (i > 0) try w.writeAll(", ");
                const comp_name = names.get(comp_id) orelse "0";
                try w.writeAll(comp_name);
            }
            try w.writeAll("};\n");
        }
    }
    try w.writeAll("\n");

    // Emit struct declarations for types used as local variables
    var local_structs_glsl = std.AutoHashMap(u32, void).init(aa);
    defer local_structs_glsl.deinit();
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                const ptr_type = inst.words[1];
                const ptr_inst = getDef(&module, ptr_type) orelse continue;
                if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                    var pointee_id = ptr_inst.words[3];
                    var pt_inst = getDef(&module, pointee_id) orelse continue;
                    // Unwrap array types to find underlying struct
                    while (pt_inst.op == .TypeArray and pt_inst.words.len > 2) {
                        pointee_id = pt_inst.words[2];
                        pt_inst = getDef(&module, pointee_id) orelse break;
                    }
                    if (pt_inst.op == .TypeStruct) {
                        emitOneStructForwardDecl(&module, &names, pointee_id, w, aa, &local_structs_glsl, &emitted_names) catch {};
                    }
                }
            }
        }
    }
    if (local_structs_glsl.count() > 0) try w.writeAll("\n");

    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| { if (inst.op == .Function and inst.words.len > 2) try func_ids.append(aa, inst.words[2]); }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer { var it = out_param_info.iterator(); while(it.next())|e| e.value_ptr.deinit(aa); out_param_info.deinit(); }
    detectOutParams(&module, entry_id, &out_param_info, aa);

    for (func_ids.items) |fid| { if (fid == entry_id) continue; try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info, options.version); }
    try emitFunction(&module, &names, &decs, entry_id, w, aa, true, &out_param_info, options.version);
    output_owned = false;
    return output.toOwnedSlice(alloc);
}

// ---- Parser (identical to HLSL backend) ----
fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;
    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch return error.OutOfMemory;
    errdefer instructions.deinit(alloc);
    // Use flat array for ID lookups — O(1) without hashing
    const bound = if (words.len > 3) words[3] else 0;
    const id_defs = try alloc.alloc(?usize, bound);
    @memset(id_defs, null);
    var i: usize = 5;
    while (i < words.len) {
        const hw = words[i]; const wc: u16 = @intCast(hw >> 16); const oc: u16 = @truncate(hw & 0xFFFF);
        if (wc == 0) return error.InvalidSpirv;
        if (i + wc > words.len) return error.InvalidSpirvTruncated;
        const op: spirv.Op = @enumFromInt(oc); const iw = words[i..i+wc];
        if (resultIdFromOp(op, iw)) |id| { if (id < bound) id_defs[id] = instructions.items.len; }
        instructions.append(alloc, .{.op=op,.words=iw}) catch return error.OutOfMemory;
        i += wc;
    }
    const owned = instructions.toOwnedSlice(alloc) catch instructions.items;
    var module = ParsedModule{.instructions=owned,.id_defs=id_defs};
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) { if (module.entry_point_id == null) { module.execution_model = @enumFromInt(inst.words[1]); module.entry_point_id = inst.words[2]; } }
        if (inst.op == .ExecutionMode and inst.words.len >= 3) { const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]); if (mode == .LocalSize and inst.words.len >= 6) module.local_size = .{inst.words[3],inst.words[4],inst.words[5]}; }
    }
    return module;
}

fn findEntryPoint(module: *const ParsedModule, name: []const u8) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 3) {
            const bytes = std.mem.sliceAsBytes(inst.words[3..]);
            var len: usize = 0;
            while (len < bytes.len) : (len += 1) {
                if (bytes[len] == 0) break;
            }
            if (std.mem.eql(u8, bytes[0..len], name)) return inst.words[2];
        }
    }
    return null;
}

fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch(op) {
        .TypeVoid,.TypeBool,.TypeInt,.TypeFloat,.TypeVector,.TypeMatrix,.TypeImage,.TypeSampler,.TypeSampledImage,.TypeArray,.TypeRuntimeArray,.TypeStruct,.TypePointer,.TypeFunction,.TypeForwardPointer,.TypeAccelerationStructureKHR,.TypeRayQueryKHR,.TypeTensorARM => if(words.len>1) words[1] else null,
        .ConstantTrue,.ConstantFalse,.Constant,.ConstantComposite,.SpecConstant,.SpecConstantTrue,.SpecConstantFalse,.SpecConstantComposite,.SpecConstantOp,.Undef => if(words.len>2) words[2] else null,
        .Variable,.Function,.FunctionParameter => if(words.len>2) words[2] else null,
        .Load,.AccessChain,.CompositeConstruct,.CompositeExtract,.CompositeInsert,.VectorShuffle,.SampledImage,.ImageSampleImplicitLod,.ImageSampleExplicitLod,.ImageFetch,.ImageGather,.ImageQuerySizeLod,.ImageQuerySize,.ImageTexelPointer,.FunctionCall,.CopyObject,.Phi,.ConvertFToS,.ConvertSToF,.ConvertUToF,.ConvertFToU,.UConvert,.SConvert,.FConvert,.Bitcast,.SNegate,.FNegate,.IAdd,.FAdd,.ISub,.FSub,.IMul,.FMul,.UDiv,.SDiv,.FDiv,.UMod,.SRem,.SMod,.FRem,.FMod,.VectorTimesScalar,.MatrixTimesScalar,.VectorTimesMatrix,.MatrixTimesVector,.MatrixTimesMatrix,.Dot,.Transpose,.OuterProduct,.Select,.LogicalOr,.LogicalAnd,.LogicalNot,.IEqual,.INotEqual,.UGreaterThan,.SGreaterThan,.UGreaterThanEqual,.SGreaterThanEqual,.ULessThan,.SLessThan,.ULessThanEqual,.SLessThanEqual,.FOrdEqual,.FOrdNotEqual,.FOrdLessThan,.FOrdGreaterThan,.FOrdLessThanEqual,.FOrdGreaterThanEqual,.FUnordEqual,.FUnordNotEqual,.FUnordLessThan,.FUnordGreaterThan,.FUnordLessThanEqual,.FUnordGreaterThanEqual,.ShiftRightLogical,.ShiftRightArithmetic,.ShiftLeftLogical,.BitwiseOr,.BitwiseXor,.BitwiseAnd,.Not,.BitReverse,.BitCount,.BitFieldInsert,.BitFieldSExtract,.BitFieldUExtract,.IsNan,.IsInf,.All,.Any,.DPdx,.DPdy,.Fwidth,.DPdxFine,.DPdyFine,.FwidthFine,.DPdxCoarse,.DPdyCoarse,.FwidthCoarse,.VectorExtractDynamic,.ExtInst,.OpImage,.AtomicIAdd,.AtomicISub,.AtomicExchange,.AtomicSMin,.AtomicUMin,.AtomicSMax,.AtomicUMax,.AtomicAnd,.AtomicOr,.AtomicXor,.ImageSampleDrefImplicitLod,.ImageSampleDrefExplicitLod,.ImageSampleProjImplicitLod,.ImageSampleProjExplicitLod,.ImageDrefGather,.ImageQueryLod,.ImageQueryLevels,.ImageQuerySamples,.ImageRead,.AtomicCompareExchange,.AtomicFAddEXT,.ArrayLength => if(words.len>2) words[2] else null,
        else => null,
    };
}

// ---- Collection passes (identical logic to HLSL) ----
fn collectNames(alloc: std.mem.Allocator, m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    for (m.instructions) |inst| {
        if (inst.op == .Name and inst.words.len >= 3) { const id = inst.words[1]; const ns = parseLitStr(alloc, inst.words[2..]) catch continue; const san = sanitizeName(alloc, ns) catch { names.put(id, ns) catch {}; continue; }; alloc.free(ns); names.put(id, san) catch {}; }
        if (inst.op == .Constant and inst.words.len > 3) { const rid = inst.words[2]; const ti = getDef(m, inst.words[1]); if (ti) |t| { const lit = constantLiteral(alloc, t, inst.words[3..]) catch continue; if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value); continue; } }
        if (inst.op == .ConstantTrue and inst.words.len > 2) { const l = alloc.dupe(u8, "true") catch continue; if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value); continue; }
        if (inst.op == .ConstantFalse and inst.words.len > 2) { const l = alloc.dupe(u8, "false") catch continue; if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value); continue; }
        if (inst.op == .ConstantComposite and inst.words.len > 3) {
            const rid = inst.words[2];
            const ti = getDef(m, inst.words[1]);
            if (ti) |t| {
                if (t.op == .TypeVector) {
                    // Check if all constituents are the same (splat)
                    const constituents = inst.words[3..];
                    var all_same = true;
                    if (constituents.len > 1) {
                        const first = constituents[0];
                        for (constituents[1..]) |c| {
                            if (c != first) { all_same = false; break; }
                        }
                    }
                    const vt = glslType(m, inst.words[1], names, alloc) catch "vec4";
                    if (all_same and constituents.len > 0) {
                        // Splat: vec3(1.0) instead of vec3(1.0, 1.0, 1.0)
                        const val = names.get(constituents[0]) orelse "0.0";
                        const lit = std.fmt.allocPrint(alloc, "{s}({s})", .{vt, val}) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    } else {
                        var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                        defer buf.deinit(alloc);
                        buf.print(alloc, "{s}(", .{vt}) catch continue;
                        for (constituents, 0..) |cid, i| {
                            if (i > 0) buf.appendSlice(alloc, ", ") catch continue;
                            buf.appendSlice(alloc, names.get(cid) orelse "0.0") catch continue;
                        }
                        buf.appendSlice(alloc, ")") catch continue;
                        const lit = buf.toOwnedSlice(alloc) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    }
                    continue;
                } else if (t.op == .TypeMatrix) {
                    // Matrix constants
                    const mt = glslType(m, inst.words[1], names, alloc) catch "mat4";
                    var buf = std.ArrayList(u8).initCapacity(alloc, 128) catch continue;
                    defer buf.deinit(alloc);
                    buf.print(alloc, "{s}(", .{mt}) catch continue;
                    for (inst.words[3..], 0..) |cid, i| {
                        if (i > 0) buf.appendSlice(alloc, ", ") catch continue;
                        buf.appendSlice(alloc, names.get(cid) orelse "0.0") catch continue;
                    }
                    buf.appendSlice(alloc, ")") catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                }
            }
        }
        if (resultIdFromOp(inst.op, inst.words)) |rid| { if (!names.contains(rid)) { const name = std.fmt.allocPrint(alloc, "v{}", .{counter}) catch continue; counter += 1; names.put(rid, name) catch {}; } }
    }

    // Deduplicate Function-scoped variable names
    // Collect all Function-scoped variable IDs grouped by name
    var name_groups = std.StringHashMapUnmanaged(std.ArrayList(u32)).empty;
    defer { var dgi = name_groups.iterator(); while (dgi.next()) |e| { alloc.free(e.key_ptr.*); e.value_ptr.deinit(alloc); } name_groups.deinit(alloc); }
    {
        var di: usize = 0;
        while (di < m.instructions.len) : (di += 1) {
            const dinst = m.instructions[di];
            if (dinst.op == .Variable and dinst.words.len >= 4) {
                const dsc: spirv.StorageClass = @enumFromInt(dinst.words[3]);
                if (dsc == .Function) {
                    const drid = dinst.words[2];
                    if (names.get(drid)) |dvn| {
                        const dvn_copy = alloc.dupe(u8, dvn) catch continue;
                        const dgop = name_groups.getOrPut(alloc, dvn_copy) catch { alloc.free(dvn_copy); continue; };
                        if (!dgop.found_existing) dgop.value_ptr.* = std.ArrayList(u32).initCapacity(alloc, 2) catch continue;
                        dgop.value_ptr.append(alloc, drid) catch {};
                    }
                }
            }
        }
    }
    // Apply renames for duplicate groups
    {
        var dgi2 = name_groups.iterator();
        while (dgi2.next()) |dentry| {
            if (dentry.value_ptr.items.len <= 1) continue;
            for (dentry.value_ptr.items, 1..) |did, dsuffix| {
                const dnew = std.fmt.allocPrint(alloc, "{s}_{d}", .{ dentry.key_ptr.*, dsuffix }) catch continue;
                _ = names.fetchPut(did, dnew) catch {};
            }
        }
    }

    // Deduplicate function-local variable names
    var func_var_ids_glsl = std.AutoHashMap(u32, void).init(alloc);
    defer func_var_ids_glsl.deinit();
    for (m.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                func_var_ids_glsl.put(inst.words[2], {}) catch {};
            }
        }
    }
    var fv_name_ids = std.StringHashMap(std.ArrayList(u32)).init(alloc);
    defer {
        var fit = fv_name_ids.iterator();
        while (fit.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        fv_name_ids.deinit();
    }
    var fvniter = func_var_ids_glsl.iterator();
    while (fvniter.next()) |entry| {
        const id = entry.key_ptr.*;
        const name = names.get(id) orelse continue;
        const gop = fv_name_ids.getOrPut(name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u32).initCapacity(alloc, 2) catch continue;
        }
        gop.value_ptr.append(alloc, id) catch {};
    }
    var fvdniter = fv_name_ids.iterator();
    while (fvdniter.next()) |entry| {
        const fvname = entry.key_ptr.*;
        const fvids = entry.value_ptr.*;
        if (fvids.items.len <= 1) continue;
        for (fvids.items, 0..) |fid, fi| {
            if (fi == 0) continue;
            const fnew = std.fmt.allocPrint(alloc, "{s}_{d}", .{ fvname, fid }) catch continue;
            names.put(fid, fnew) catch {};
        }
    }
}

fn collectDecorations(alloc: std.mem.Allocator, m: *const ParsedModule, decs: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    for (m.instructions) |inst| { if (inst.op == .Decorate and inst.words.len >= 3) { const id = inst.words[1]; const dec: spirv.Decoration = @enumFromInt(inst.words[2]); const extra = if(inst.words.len>3) inst.words[3..] else &[_]u32{}; const gop = try decs.getOrPut(id); if(!gop.found_existing) gop.value_ptr.* = std.ArrayList(DecorationEntry).empty; try gop.value_ptr.append(alloc, .{.decoration=dec,.extra=extra}); } }
}

fn collectResources(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), cb: *std.ArrayList(CbufferDecl), tex: *std.ArrayList(TextureDecl), alloc: std.mem.Allocator) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const rt = inst.words[1]; const rid = inst.words[2]; const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        const pi = getDef(m, rt) orelse continue; if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        switch (sc) {
            // Exclude SSBOs from the cbuffer list. `BufferBlock` is decorated on the STRUCT
            // TYPE (`structHasBufferBlock(pt)`) — the variable-id check `hasDec(rid,…)` is a
            // defensive no-op for spec-conformant SPIR-V but kept for any producer that mis-
            // decorates the variable. The struct-type exclusion is compute-gated so non-compute
            // SSBOs (not declared by the compute-only SSBO loop) stay on the uniform path.
            .Uniform => { if (hasDec(decs, rid, .buffer_block) or (m.execution_model == .GLCompute and structHasBufferBlock(m, pt))) continue; const binding = getDecVal(decs, rid, .binding) orelse 0; cb.append(alloc, .{.name=names.get(rid) orelse "Globals", .type_id=pt, .binding=binding}) catch {}; },
            .UniformConstant => { var pei = getDef(m, pt) orelse continue; const binding = getDecVal(decs, rid, .binding) orelse 0; const name = names.get(rid) orelse "tex"; var arr_sz: u32 = 0; if (pei.op == .TypeArray and pei.words.len > 3) { const li = getDef(m, pei.words[3]); arr_sz = if (li != null and li.?.op == .Constant and li.?.words.len > 3) li.?.words[3] else 0; pei = getDef(m, pei.words[2]) orelse continue; } switch(pei.op){ .TypeSampledImage=>{ const si_img = if (pei.words.len > 2) getDef(m, pei.words[2]) else null; const si_st = if (si_img != null and si_img.?.words.len > 2) getDef(m, si_img.?.words[2]) else null; const si_uint = si_st != null and si_st.?.op == .TypeInt and si_st.?.words.len > 3 and si_st.?.words[3] == 0; const si_int = si_st != null and si_st.?.op == .TypeInt and si_st.?.words.len > 3 and si_st.?.words[3] != 0; const si_dim: []const u8 = blk: { if (si_img != null and si_img.?.words.len > 3) { break :blk switch(si_img.?.words[3]) { 0 => "1D", 1 => "2D", 2 => "3D", 3 => "Cube", 4 => "Rect", 5 => "Buffer", 6 => "SubpassData", else => "2D" }; } break :blk "2D"; }; const si_arrayed = si_img != null and si_img.?.words.len > 5 and si_img.?.words[5] == 1; tex.append(alloc,.{.name=name,.binding=binding,.is_uint=si_uint,.is_int=si_int,.dim_str=si_dim,.array_size=arr_sz,.arrayed=si_arrayed}) catch {};}, .TypeImage=>{ const sampled: u32 = if (pei.words.len > 7) pei.words[7] else 0; const is_storage = sampled == 2; const st_inst = if (pei.words.len > 2) getDef(m, pei.words[2]) else null; const is_uint = st_inst != null and st_inst.?.op == .TypeInt and st_inst.?.words.len > 3 and st_inst.?.words[3] == 0; const is_int = st_inst != null and st_inst.?.op == .TypeInt and st_inst.?.words.len > 3 and st_inst.?.words[3] != 0; const fmt: []const u8 = blk: { if (pei.words.len > 8) { break :blk switch(pei.words[8]) { 0 => "rgba8f", 1 => "rgba32f", 2 => "rgba16f", 3 => "r32f", 4 => "rgba8", 5 => "rgba8_snorm", 6 => "rg32f", 7 => "rg16f", 8 => "r11f_g11f_b10f", 9 => "r16f", 10 => "rgba16", 11 => "rgb10_a2", 12 => "rg8", 13 => "rg8_snorm", 14 => "r8", 15 => "r8_snorm", 16 => "rgba16_snorm", 17 => "rgba32i", 18 => "rgba16i", 19 => "rgba8i", 20 => "rg32i", 21 => "rg16i", 22 => "rg8i", 23 => "r32i", 24 => "rgba32ui", 25 => "rgba16ui", 26 => "rgba8ui", 27 => "rg32ui", 28 => "rg16ui", 29 => "rg8ui", 30...33 => "r32ui", else => "rgba8f" }; } break :blk "rgba8f"; }; const dim: []const u8 = blk: { if (pei.words.len > 3) { break :blk switch(pei.words[3]) { 0 => "1D", 1 => "2D", 2 => "3D", 3 => "Cube", 4 => "Rect", 5 => "Buffer", 6 => "SubpassData", else => "2D" }; } break :blk "2D"; }; const img_arrayed = pei.words.len > 5 and pei.words[5] == 1; tex.append(alloc,.{.name=name,.binding=binding,.is_storage=is_storage,.format_str=fmt,.dim_str=dim,.is_uint=is_uint,.is_int=is_int,.array_size=arr_sz,.arrayed=img_arrayed}) catch {};}, else=>{}} },
            else => {},
        }
    }
}

fn getMemberName(m: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    return common.commonGetMemberName(m.instructions, struct_id, member_idx, buf, "m");
}

// `original_names = false` (uniform/cbuffer blocks): members are named `{cb_name}_m{idx}`
// to match the cbuffer access path (`{cb}_1.{cb}_m{idx}`). `original_names = true` (SSBO
// storage blocks): members keep their ORIGINAL names (`getMemberName`) and emit array
// brackets — `[N]` for a sized array, `[]` for a runtime array (`OpTypeRuntimeArray`) — to
// match the SSBO body access (`B.d`) and enable native `.length()`. The two callers
// disagreed before, producing glslang-rejected desynced output for SSBOs (#296).
fn emitStructMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, cb_name: []const u8, w: anytype, alloc: std.mem.Allocator, original_names: bool) !void {
    const inst = getDef(m, struct_id) orelse return; if (inst.op != .TypeStruct) return;
    for (inst.words[2..], 0..) |mt_id, mi| {
        var mbuf: [32]u8 = undefined;
        const mname: []const u8 = if (original_names) getMemberName(m, struct_id, @intCast(mi), &mbuf) else "";
        const mti = getDef(m, mt_id);
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const et = try glslType(m, mi2.words[2], names, alloc);
                const li = getDef(m, mi2.words[3]); const lv: u32 = if(li)|l| (if (l.words.len > 3) l.words[3] else 1) else 1;
                if (original_names) try w.print("    {s} {s}[{d}];\n", .{et, mname, lv})
                else try w.print("    {s} {s}_m{d}[{d}];\n", .{et, cb_name, mi, lv});
                continue;
            }
            if (mi2.op == .TypeRuntimeArray and mi2.words.len > 2) {
                const et = try glslType(m, mi2.words[2], names, alloc);
                if (original_names) try w.print("    {s} {s}[];\n", .{et, mname})
                else try w.print("    {s} {s}_m{d}[];\n", .{et, cb_name, mi});
                continue;
            }
        }
        const mt = try glslType(m, mt_id, names, alloc);
        if (original_names) try w.print("    {s} {s};\n", .{mt, mname})
        else try w.print("    {s} {s}_m{d};\n", .{mt, cb_name, mi});
    }
}

/// Collect struct type IDs referenced (transitively) by a parent type, and emit forward declarations.
/// Only emits types referenced INSIDE the root type (not the root type itself).
fn emitStructForwardDecls(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitStructForwardDecls(m, names, root_type_id, w, alloc, emitted, emitted_names, glslType, getMemberName);
}

fn emitOneStructForwardDecl(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitOneStructForwardDecl(m, names, type_id, w, alloc, emitted, emitted_names, glslType, getMemberName);
}

fn detectOutParams(m: *const ParsedModule, entry_id: u32, opi: *std.AutoHashMap(u32, std.ArrayList(usize)), alloc: std.mem.Allocator) void {
    const fi = if (entry_id < m.id_defs.len) m.id_defs[entry_id] orelse return else return;
    var ov = std.AutoHashMap(u32, void).init(alloc); defer ov.deinit();
    for (m.instructions) |inst| { if (inst.op == .Variable and inst.words.len >= 4) { const sc: spirv.StorageClass = @enumFromInt(inst.words[3]); if (sc == .Output) ov.put(inst.words[2], {}) catch {}; } }
    var lfo = std.AutoHashMap(u32, void).init(alloc); defer lfo.deinit();
    for (m.instructions) |inst| { if (inst.op == .Load and inst.words.len >= 4) { if (ov.contains(inst.words[3])) lfo.put(inst.words[2], {}) catch {}; } }
    var idx = fi + 1;
    while (idx < m.instructions.len) : (idx += 1) { const inst = m.instructions[idx]; if (inst.op == .FunctionEnd) break; if (inst.op != .FunctionCall or inst.words.len < 4) continue; const cfid = inst.words[3]; for (inst.words[4..], 0..) |aid, pidx| { if (ov.contains(aid) or lfo.contains(aid)) { const gop = opi.getOrPut(cfid) catch continue; if(!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).initCapacity(alloc, 4) catch continue; gop.value_ptr.append(alloc, pidx) catch {}; } } }
}

// ---- Std450 → GLSL function name mapping ----
fn std450ToGlsl(val: u32) ?[]const u8 {
    return switch (val) {
        1 => "round", 2 => "roundEven", 3 => "trunc", 4, 5 => "abs", 6, 7 => "sign", 8 => "floor", 9 => "ceil",
        10 => "fract",
        11 => "radians", 12 => "degrees", 13 => "sin", 14 => "cos", 15 => "tan",
        16 => "asin", 17 => "acos", 18 => "atan", 19 => "sinh", 20 => "cosh", 21 => "tanh",
        22 => "asinh", 23 => "acosh", 24 => "atanh",
        25 => "atan", 26 => "pow", 27 => "exp", 28 => "log", 29 => "exp2", 30 => "log2",
        31 => "sqrt", 32 => "inversesqrt", 33 => "determinant",
        34 => "inverse",
        36 => "modf",
        // GLSL.std.450 spec order: FMin(37) UMin(38) SMin(39) FMax(40) UMax(41) SMax(42).
        37 => "min", 38 => "min", 39 => "min",
        40 => "max", 41 => "max", 42 => "max", 43 => "clamp", 44 => "clamp",
        45 => "clamp", 46 => "mix", 48 => "step", 49 => "smoothstep",
        50 => "fma",
        52 => "frexp",
        53 => "ldexp",
        66 => "length", 67 => "distance", 68 => "cross", 69 => "normalize",
        70 => "faceforward", 71 => "reflect", 72 => "refract",
        73 => "findLSB", 74 => "findMSB", 75 => "findMSB",
        35 => "modf",
        51 => "frexp",
        76 => "interpolateAtCentroid", 77 => "interpolateAtSample", 78 => "interpolateAtOffset",
        54 => "packSnorm4x8", 55 => "packUnorm4x8",
        56 => "packSnorm2x16", 57 => "packUnorm2x16", 58 => "packHalf2x16",
        60 => "unpackSnorm2x16", 61 => "unpackUnorm2x16", 62 => "unpackHalf2x16",
        63 => "unpackSnorm4x8", 64 => "unpackUnorm4x8",
        79 => "min", 80 => "max", 81 => "clamp",
        else => null,
    };
}

// ---- Function emission (GLSL dialect) ----
// Part 2 of spirv_to_glsl.zig — emit functions
// This content gets appended to the main file.

fn emitFunction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    is_entry: bool,
    opi: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    version: u32,
) !void {
    const fi = getDef(m, func_id) orelse return;
    if (fi.op != .Function or fi.words.len < 5) return;
    const fti = getDef(m, fi.words[4]) orelse return;
    const rtid = fti.words[2];
    const rt = try glslType(m, rtid, names, alloc);
    const is_frag = is_entry and m.execution_model == .Fragment;

    var output_var_id: ?u32 = null;
    var input_var_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer input_var_ids.deinit(alloc);
    // Full list of stage Output variables (for the in/out varying declarations
    // below). `output_var_id` stays the single fragment primary-color output to
    // preserve the fragment body's return handling unchanged.
    var output_var_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer output_var_ids.deinit(alloc);
    if (is_entry) {
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) {
                    output_var_ids.append(alloc, inst.words[2]) catch {};
                    if (is_frag) {
                        // Prefer user-defined outputs (with location) over builtins
                        const bi = getDecVal(decs, inst.words[2], .built_in);
                        if (bi == null) {
                            output_var_id = inst.words[2];
                        } else if (output_var_id == null) {
                            output_var_id = inst.words[2];
                        }
                    }
                } else if (sc == .Input) {
                    input_var_ids.append(alloc, inst.words[2]) catch {};
                }
            }
        }
    }

    const func_idx = if (func_id < m.id_defs.len) m.id_defs[func_id] orelse return else return;
    const func_name = names.get(func_id) orelse "func";

    var param_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer param_ids.deinit(alloc);
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionParameter) {
                try param_ids.append(alloc, inst.words[2]);
            } else if (inst.op != .Label) {
                break;
            }
        }
    }

    // Out-param detection: Variable + Store(param) pattern
    var out_param_var_ids = std.AutoHashMap(u32, u32).init(alloc);
    defer out_param_var_ids.deinit();
    {
        var si = func_idx + 1;
        while (si < m.instructions.len) : (si += 1) {
            const scan = m.instructions[si];
            if (scan.op == .FunctionEnd) break;
            if (scan.op == .Label or scan.op == .FunctionParameter) continue;
            if (scan.op == .Variable and scan.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(scan.words[3]);
                if (sc == .Function) {
                    const vid = scan.words[2];
                    if (si + 1 < m.instructions.len) {
                        const next = m.instructions[si + 1];
                        if (next.op == .Store and next.words.len >= 3 and next.words[1] == vid) {
                            const sv = next.words[2];
                            for (param_ids.items) |pid| {
                                if (pid == sv) {
                                    out_param_var_ids.put(pid, vid) catch {};
                                    const pn = names.get(pid) orelse "p";
                                    const pa = alloc.dupe(u8, pn) catch continue;
                                    if (names.fetchPut(vid, pa) catch null) |old| alloc.free(old.value);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (scan.op != .Variable and scan.op != .Store) break;
        }
    }

    // Call-site out-param detection
    // For each FunctionCall in this function, check if arguments match out-param patterns
    if (opi.get(func_id)) |_| {
        var si3 = func_idx + 1;
        while (si3 < m.instructions.len) : (si3 += 1) {
            const si = m.instructions[si3];
            if (si.op == .FunctionEnd) break;
            if (si.op != .FunctionCall or si.words.len < 4) continue;
            const called_fid = si.words[3];
            const call_out_params = opi.get(called_fid) orelse continue;
            // For each out-param position of the called function
            for (call_out_params.items) |pi| {
                if (pi + 4 >= si.words.len) continue;
                const arg_id = si.words[4 + pi]; // actual argument ID
                // Only rename if arg is a Function-scoped variable
                const arg_def = getDef(m, arg_id) orelse continue;
                if (arg_def.op != .Variable) continue;
                if (arg_def.words.len < 4) continue;
                const asc: spirv.StorageClass = @enumFromInt(arg_def.words[3]);
                if (asc != .Function) continue;
                // Don't rename if this variable already got a name from definition-level detection
                if (out_param_var_ids.contains(arg_id)) continue;
                // Get the parameter name from the called function
                const called_param_ids = blk: {
                    var cpi = std.ArrayList(u32).initCapacity(alloc, 4) catch break :blk &.{};
                    var ci = func_idx + 1;
                    while (ci < m.instructions.len) : (ci += 1) {
                        const cinst = m.instructions[ci];
                        if (cinst.op == .FunctionEnd) break;
                        if (cinst.op == .FunctionParameter) {
                            cpi.append(alloc, cinst.words[2]) catch {};
                        }
                    }
                    break :blk cpi.items;
                };
                if (pi < called_param_ids.len) {
                    const pname = names.get(called_param_ids[pi]) orelse "p";
                    const pa = alloc.dupe(u8, pname) catch continue;
                    if (names.fetchPut(arg_id, pa) catch null) |old| alloc.free(old.value);
                }
            }
        }
    }

    // Emit input/output varying declarations before the entry function, for ALL
    // stages. Non-builtin inputs → `layout(location=N) in T name;`, non-builtin
    // outputs → `layout(location=N) out T name;`. Built-ins (gl_Position,
    // gl_FragCoord, gl_VertexIndex, gl_FragDepth, ...) are predefined in GLSL —
    // never declared here; builtin INPUTS are aliased to their gl_* name below.
    // (Previously only the single fragment color output was declared, so vertex
    // varyings, vertex attributes, and fragment input varyings were emitted as
    // undeclared identifiers — invalid GLSL.)
    if (is_entry) {
        var emitted_any_io = false;
        for (input_var_ids.items) |ivid| {
            if (getDecVal(decs, ivid, .built_in) != null) continue;
            // gl_PerVertex-style built-in blocks carry BuiltIn on their members
            // (OpMemberDecorate), not on the variable — skip them: the members are
            // predefined in GLSL and re-declaring the block is invalid.
            if (isBuiltinBlockVar(m, ivid)) continue;
            const iv = getDef(m, ivid) orelse continue;
            const it = try glslType(m, iv.words[1], names, alloc);
            const in_name = names.get(ivid) orelse continue;
            // GLSL requires `flat` interpolation on integer/double fragment
            // inputs (glslang: "'int' : must be qualified as flat in"). The
            // frontend preserves the source qualifier as an `OpDecorate … Flat`;
            // emit it whenever present (never fabricate — only what the SPIR-V
            // says). Applies symmetrically to flat vertex outputs below.
            const flat_q: []const u8 = if (hasDec(decs, ivid, .flat)) "flat " else "";
            // #169 (G4) Tier 3: below 410 glslang rejects `layout(location=)` on a
            // fragment INPUT varying (only vertex inputs may carry it). Drop the
            // qualifier there; keep it at >= 410 and for vertex inputs.
            const drop_loc = dropVaryingLocation(version, m.execution_model, .in);
            if (!drop_loc) if (getDecVal(decs, ivid, .location)) |l| {
                try w.print("layout(location = {d}) {s}in {s} {s};\n", .{ l, flat_q, it, in_name });
                emitted_any_io = true;
                continue;
            };
            try w.print("{s}in {s} {s};\n", .{ flat_q, it, in_name });
            emitted_any_io = true;
        }
        for (output_var_ids.items) |ovid| {
            if (getDecVal(decs, ovid, .built_in) != null) continue;
            // Skip gl_PerVertex (built-in block): glslang rejects `out gl_PerVertex;`
            // and spirv-cross omits it — gl_Position et al. are predefined. The
            // BuiltIn decorations live on the struct members, so the variable-level
            // built_in check above doesn't catch it.
            if (isBuiltinBlockVar(m, ovid)) continue;
            const ov = getDef(m, ovid) orelse continue;
            const ot = try glslType(m, ov.words[1], names, alloc);
            const on = names.get(ovid) orelse "_out";
            // Mirror the input side: a `flat out` (e.g. integer varying from a
            // vertex stage) carries an `OpDecorate … Flat`; preserve it.
            const flat_q: []const u8 = if (hasDec(decs, ovid, .flat)) "flat " else "";
            // #169 (G4) Tier 3: below 410 glslang rejects `layout(location=)` on a
            // vertex OUTPUT varying (only fragment outputs may carry it). Drop it
            // there; keep it at >= 410 and for fragment outputs.
            const drop_loc = dropVaryingLocation(version, m.execution_model, .out);
            if (!drop_loc) if (getDecVal(decs, ovid, .location)) |l| {
                try w.print("layout(location = {d}) {s}out {s} {s};\n", .{ l, flat_q, ot, on });
                emitted_any_io = true;
                continue;
            };
            try w.print("{s}out {s} {s};\n", .{ flat_q, ot, on });
            emitted_any_io = true;
        }
        if (emitted_any_io) try w.writeAll("\n");
    }

    try w.print("{s} {s}(", .{ rt, func_name });

    for (param_ids.items, 0..) |pid, i| {
        if (i > 0) try w.writeAll(", ");
        const pi = getDef(m, pid).?;
        const pn = names.get(pid) orelse "p";
        const pti = getDef(m, pi.words[1]);
        var is_out = false;
        var itid = pi.words[1];
        if (pti) |pt| {
            if (pt.op == .TypePointer and pt.words.len > 3) {
                itid = pt.words[3];
            }
        }
        if (out_param_var_ids.contains(pid)) {
            is_out = true;
            itid = pi.words[1];
        }
        if (!is_out) {
            if (opi.get(func_id)) |oindices| {
                for (oindices.items) |oi| {
                    if (oi == i) {
                        is_out = true;
                        break;
                    }
                }
            }
        }
        const pt2 = try glslType(m, itid, names, alloc);
        if (is_out) try w.writeAll("out ");
        try w.print("{s} {s}", .{ pt2, pn });
    }

    // For GLSL entry points: built-in input vars (gl_FragCoord, gl_VertexIndex,
    // gl_GlobalInvocationID, ...) are predefined; alias them by name so the body
    // references the GLSL builtin instead of an undeclared identifier. Applies to
    // every stage (vertex/compute builtins too), not just fragment.
    if (is_entry) {
        for (input_var_ids.items) |ivid| {
            const iv_name = names.get(ivid) orelse continue;
            // Check if this input has a BuiltIn decoration
            const builtin = getDecVal(decs, ivid, .built_in);
            if (builtin) |bi| {
                const builtin_name: []const u8 = switch (@as(spirv.BuiltIn, @enumFromInt(bi))) {
                    .position => "gl_FragCoord",
                    .frag_coord => "gl_FragCoord",
                    .point_size => "gl_PointSize",
                    .clip_distance => "gl_ClipDistance",
                    .cull_distance => "gl_CullDistance",
                    .front_facing => "gl_FrontFacing",
                    .sample_position => "gl_SamplePosition",
                    .sample_mask => "gl_SampleMaskIn",
                    .sample_id => "gl_SampleID",
                    .global_invocation_id => "gl_GlobalInvocationID",
                    .local_invocation_id => "gl_LocalInvocationID",
                    .workgroup_id => "gl_WorkGroupID",
                    .num_workgroups => "gl_NumWorkGroups",
                    .local_invocation_index => "gl_LocalInvocationIndex",
                    .vertex_id => "gl_VertexID",
                    .instance_id => "gl_InstanceID",
                    .base_vertex => "gl_BaseVertex",
                    .base_instance => "gl_BaseInstance",
                    .draw_index => "gl_DrawID",
                    .device_index => "gl_DeviceIndex",
                    .view_index => "gl_ViewIndex",
                    .layer => "gl_Layer",
                    .primitive_id => "gl_PrimitiveID",
                    .invocation_id => "gl_InvocationID",
                    else => iv_name,
                };
                if (!std.mem.eql(u8, iv_name, builtin_name)) {
                    const a = alloc.dupe(u8, builtin_name) catch continue;
                    if (names.fetchPut(ivid, a) catch null) |old| alloc.free(old.value);
                }
            }
        }
    }

    try w.writeAll(")\n{\n");

    // For compute shaders: emit shared variable declarations
    if (is_entry and m.execution_model == .GLCompute) {
        var si = func_idx + 1;
        while (si < m.instructions.len) : (si += 1) {
            const inst = m.instructions[si];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Workgroup) {
                    const ri = inst.words[2];
                    const tn = try glslType(m, inst.words[1], names, alloc);
                    try w.print("    shared {s} {s};\n", .{tn, names.get(ri) orelse "shared_var"});
                }
            }
        }
    }

    try emitBody(m, names, decs, func_idx, w, alloc, is_frag, output_var_id);
    try w.writeAll("}\n");
}

fn emitBody(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_idx: usize,
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    output_var_id: ?u32,
) !void {
    var label_map = std.AutoHashMap(u32, usize).init(alloc);
    defer label_map.deinit();
    { var idx = func_idx + 1; while (idx < m.instructions.len) : (idx += 1) { const inst = m.instructions[idx]; if (inst.op == .FunctionEnd) break; if (inst.op == .Label and inst.words.len > 1) label_map.put(inst.words[1], idx) catch {}; } }

    var bc_merge = std.AutoHashMap(usize, u32).init(alloc);
    defer bc_merge.deinit();
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .SelectionMerge and inst.words.len > 1) {
                const ml = inst.words[1];
                { var j = idx + 1; while (j < m.instructions.len) : (j += 1) { const n = m.instructions[j]; if (n.op == .BranchConditional) { bc_merge.put(j, ml) catch {}; break; } if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break; if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break; } }
                { var k = idx + 1; while (k < m.instructions.len) : (k += 1) { const n = m.instructions[k]; if (n.op == .Switch) { bc_merge.put(k, ml) catch {}; break; } if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break; if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break; } }
            }
        }
    }

    // Pre-pass: identify loop-header OpPhi (loop counters) — see spirv_to_hlsl.zig.
    // The maps are exposed via file-scope state (g_*) so emitWhileLoop and emitBlock
    // can read them without threading params through emitBlock's many call sites.
    var loop_phis = std.AutoHashMap(usize, std.ArrayList(PhiInfo)).init(alloc);
    var phi_hdr = std.AutoHashMap(u32, usize).init(alloc);
    var deferred_hdr = std.AutoHashMap(usize, void).init(alloc);
    defer {
        var lpit = loop_phis.valueIterator();
        while (lpit.next()) |list| list.deinit(alloc);
        loop_phis.deinit();
        phi_hdr.deinit();
        deferred_hdr.deinit();
        g_loop_phis = null;
        g_phi_hdr = null;
        g_deferred_hdr = null;
    }
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            var hlabel_idx: usize = li;
            while (hlabel_idx > func_idx) : (hlabel_idx -= 1) {
                if (m.instructions[hlabel_idx].op == .Label) break;
            }
            var plist = std.ArrayList(PhiInfo).initCapacity(alloc, 2) catch continue;
            var p = hlabel_idx + 1;
            while (p < li) : (p += 1) {
                const pinst = m.instructions[p];
                if (pinst.op != .Phi or pinst.words.len < 5) continue;
                var init_id: u32 = pinst.words[3];
                var update_id: u32 = if (pinst.words.len >= 6) pinst.words[5] else pinst.words[3];
                var pp: usize = 3;
                while (pp + 1 < pinst.words.len) : (pp += 2) {
                    if (label_map.get(pinst.words[pp + 1])) |lx| {
                        if (lx < hlabel_idx) init_id = pinst.words[pp] else update_id = pinst.words[pp];
                    }
                }
                plist.append(alloc, .{ .result_id = pinst.words[2], .type_id = pinst.words[1], .init_id = init_id, .update_id = update_id }) catch {};
                phi_hdr.put(pinst.words[2], li) catch {};
            }
            loop_phis.put(li, plist) catch plist.deinit(alloc);
            if (li + 1 < m.instructions.len and m.instructions[li + 1].op == .BranchConditional) {
                var d = hlabel_idx + 1;
                while (d < li) : (d += 1) {
                    if (m.instructions[d].op != .Phi) deferred_hdr.put(d, {}) catch {};
                }
            }
        }
    }
    g_loop_phis = &loop_phis;
    g_phi_hdr = &phi_hdr;
    g_deferred_hdr = &deferred_hdr;

    var idx = func_idx + 1;
    while (idx < m.instructions.len) : (idx += 1) {
        const inst = m.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (isDeferredHdrGLSL(idx)) continue;
        if (try tryEmitLoopPhiDeclGLSL(m, names, inst, w, alloc, "    ")) continue;
        if (inst.op == .FunctionParameter or inst.op == .Label or inst.op == .SelectionMerge or inst.op == .Branch) continue;

        // Handle LoopMerge: emit while(true) { condition; if (!cond) break; body; }
        if (inst.op == .LoopMerge and inst.words.len >= 3) {
            const merge_lbl = inst.words[1];
            const cont_lbl = inst.words[2];
            idx = try emitWhileLoop(m, names, decs, idx, merge_lbl, cont_lbl, &label_map, &bc_merge, w, alloc, is_frag, output_var_id);
            continue;
        }

        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                const he = fl != null and fl.? != mval;
                // Scan merge block for Phi nodes to pre-declare
                const merge_idx = label_map.get(mval) orelse m.instructions.len;
                var phi_decls = std.ArrayList(struct { result_id: u32, type_id: u32, vals: [2]u32, preds: [2]u32 }).initCapacity(alloc, 4) catch unreachable;
                defer phi_decls.deinit(alloc);
                if (merge_idx < m.instructions.len) {
                    var mi2: usize = merge_idx + 1;
                    while (mi2 < m.instructions.len) : (mi2 += 1) {
                        const minst = m.instructions[mi2];
                        if (minst.op != .Phi) break;
                        if (minst.words.len >= 7) {
                            phi_decls.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
                        }
                    }
                }
                for (phi_decls.items) |pv| {
                    const rtt = glslType(m, pv.type_id, names, alloc) catch "float";
                    const vn = names.get(pv.result_id) orelse "pv";
                    try w.print("    {s} {s}_phi;\n", .{ rtt, vn });
                }
                try w.print("    if ({s})\n    {{\n", .{cn});
                idx = try emitBlock(m, names, decs, tl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", false);
                // After true branch: assign Phi vars
                for (phi_decls.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const true_val = if (pv.preds[1] == tl) pv.vals[1] else pv.vals[0];
                    const tvn = exprName(m, names, true_val, alloc);
                    try w.print("        {s}_phi = {s};\n", .{ vn, tvn });
                }
                if (he) {
                    try w.writeAll("    } else {\n");
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", false);
                    // After false branch: assign Phi vars
                    for (phi_decls.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const false_val = if (pv.preds[1] != tl) pv.vals[1] else pv.vals[0];
                        const fvn = exprName(m, names, false_val, alloc);
                        try w.print("        {s}_phi = {s};\n", .{ vn, fvn });
                    }
                }
                try w.writeAll("    }\n");
                // Map Phi result IDs to _phi names
                for (phi_decls.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                    if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                }
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                // No OpSelectionMerge on an OpBranchConditional = unstructured
                // control flow. The previous convergence-guessing if/else
                // reconstruction was a heuristic that can silently mis-nest or
                // drop branches (same lossy class as the switch path). glslpp's
                // own frontend always emits merge info; refuse external/optimized
                // unstructured SPIR-V loudly rather than emit a lossy
                // reconstruction. Full CFG structurization is backlog #4 (G2).
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        if (inst.op == .Switch) {
            if (inst.words.len < 3) continue;
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                try w.print("    switch ({s}) {{\n", .{sn});
                if (dl != mval) {
                    try w.writeAll("    default:\n");
                    _ = try emitBlock(m, names, decs, dl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", true);
                }
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == mval) continue;
                    try w.print("    case {d}:\n", .{cv});
                    _ = try emitBlock(m, names, decs, target, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", true);
                }
                try w.writeAll("    }\n");
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                // No OpSelectionMerge on an OpSwitch = unstructured control flow
                // (e.g. externally-optimized / hand-authored SPIR-V; glslpp's own
                // frontend always emits merge info). The previous convergence-
                // guessing heuristic was SILENT-WRONG — it dropped the `default`
                // case (and elided the whole switch when no convergence was
                // found). Per Mitchell discipline, fail loud instead of emitting a
                // lossy reconstruction. Full CFG structurization is backlog #4 (G2).
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, output_var_id);
    }
}

/// Resolve a do-while back-edge condition OPERAND to a GLSL expression over PERSISTENT
/// variables (#246). The C/GLSL do-while controlling expression lives OUTSIDE the body
/// block scope, so it cannot reference a body-local SSA temp — it must read the loop's
/// persistent (function-scope) variables directly. An `OpLoad ptr` therefore resolves to
/// the loaded variable's name (a fresh read at the bottom test); a constant to its
/// literal. Returns null for anything else, so the caller honest-errors.
fn inlineDoWhileOperand(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32) ?[]const u8 {
    const def = getDef(m, id) orelse return null;
    switch (def.op) {
        .Load => return if (def.words.len > 3) names.get(def.words[3]) else null,
        .Constant => return if (def.words.len > 3) names.get(def.words[2]) else null,
        .ConstantTrue => return "true",
        .ConstantFalse => return "false",
        // Any other operand (e.g. an arithmetic intermediate `OpIAdd …`) is a body-local
        // SSA temp that would be OUT OF SCOPE in the do-while controlling expression —
        // return null so the caller honest-errors instead of emitting invalid GLSL.
        else => return null,
    }
}

/// Try to rebuild a do-while back-edge condition (the SSA id tested by the latch
/// `OpBranchConditional`) as an inline GLSL expression over persistent variables (#246).
/// Handles a single comparison `a OP b` whose operands are loads-of-vars or constants —
/// the common loop-condition shape. Returns null for compound (`&&`/`||`, which SPIR-V
/// renders as explicit branches) or otherwise non-trivial conditions, so the caller can
/// fall back to the honest-error path rather than emit a body-local temp that would be
/// out of scope in the controlling expression.
fn tryInlineDoWhileCond(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), cond_id: u32, alloc: std.mem.Allocator) ?[]const u8 {
    const def = getDef(m, cond_id) orelse return null;
    const op_str: ?[]const u8 = switch (def.op) {
        .SLessThan, .ULessThan, .FOrdLessThan => "<",
        .SGreaterThan, .UGreaterThan, .FOrdGreaterThan => ">",
        .SLessThanEqual, .ULessThanEqual, .FOrdLessThanEqual => "<=",
        .SGreaterThanEqual, .UGreaterThanEqual, .FOrdGreaterThanEqual => ">=",
        .IEqual, .FOrdEqual => "==",
        // glslang lowers every GLSL float `!=` to the UNORDERED OpFUnordNotEqual, and
        // GLSL's `!=` operator is itself unordered (true on NaN) → an exact 1:1 match.
        // Only FUnordNotEqual is added here: the other FUnord* compares have no ordered-
        // operator equivalent (==,<,>,<=,>= are all ordered, NaN→false), so this inline
        // path deliberately leaves them to honest-error rather than risk a NaN-silent-
        // wrong mapping. (#170)
        .INotEqual, .FOrdNotEqual, .FUnordNotEqual => "!=",
        else => null,
    };
    if (op_str) |ops| {
        if (def.words.len < 5) return null;
        const lhs = inlineDoWhileOperand(m, names, def.words[3]) orelse return null;
        const rhs = inlineDoWhileOperand(m, names, def.words[4]) orelse return null;
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lhs, ops, rhs }) catch null;
    }
    // A bare boolean condition: a direct load of a bool variable.
    if (def.op == .Load and def.words.len > 3) return names.get(def.words[3]);
    return null;
}

/// A do-while (bottom-test) loop's CONTINUE block ends in a back-edge
/// `OpBranchConditional` whose two targets are exactly {header, merge}. A normal
/// top-test loop's continue block ends in an unconditional `OpBranch header`.
/// Returns the instruction index of that back-edge BranchConditional, else null.
/// This must be consulted BEFORE scanning the body for a condition (issue #244):
/// otherwise a body-local `if` is mis-detected as the loop condition.
fn detectDoWhileBackEdge(
    m: *const ParsedModule,
    cont_lbl: u32,
    header_lbl: u32,
    merge_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) ?usize {
    const ci = label_map.get(cont_lbl) orelse return null;
    var s = ci + 1;
    while (s < m.instructions.len) : (s += 1) {
        const t = m.instructions[s];
        if (t.op == .Label or t.op == .FunctionEnd) return null;
        if (t.op == .Branch) return null; // unconditional back-edge = top-test loop
        if (t.op == .BranchConditional and t.words.len >= 4) {
            const a = t.words[2];
            const b = t.words[3];
            if ((a == header_lbl and b == merge_lbl) or (a == merge_lbl and b == header_lbl)) return s;
            return null;
        }
    }
    return null;
}

fn emitWhileLoop(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    loop_idx: usize,
    merge_lbl: u32,
    cont_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    bc_merge: *const std.AutoHashMap(usize, u32),
    w: anytype, alloc: std.mem.Allocator,
    is_frag: bool, ovid: ?u32,
) anyerror!usize {
    // Two patterns after LoopMerge:
    // Pattern A: LoopMerge; Branch cond_label; ...; BranchConditional cond, body, merge
    // Pattern B: LoopMerge; BranchConditional cond, body, merge (merged condition)

    var bc_idx: usize = loop_idx + 1;
    var cond_start: ?usize = null; // start of condition instructions (Pattern A only)
    var cond_end: usize = loop_idx + 1;
    var is_do_while = false; // pattern C: condition tested at the back-edge (do-while)
    var dw_loop_when_true = true;

    if (loop_idx + 1 >= m.instructions.len) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    // Header label = nearest Label before the LoopMerge (needed for do-while
    // back-edge detection).
    var hlbl_idx: usize = loop_idx;
    while (hlbl_idx > 0) : (hlbl_idx -= 1) {
        if (m.instructions[hlbl_idx].op == .Label) break;
    }
    const header_lbl: u32 = if (m.instructions[hlbl_idx].words.len > 1) m.instructions[hlbl_idx].words[1] else 0;

    const next_inst = m.instructions[loop_idx + 1];
    if (next_inst.op == .Branch and next_inst.words.len >= 2) {
        // FIRST: is this a do-while (bottom-test) loop? Inspect the CONTINUE block's
        // terminator BEFORE scanning the body. Otherwise the body's own `if`
        // BranchConditional (`if(x) continue;`) is mis-grabbed as the loop condition,
        // which crashes (GLSL stack-overflow) / silently miscompiles (HLSL/MSL) — #244.
        if (detectDoWhileBackEdge(m, cont_lbl, header_lbl, merge_lbl, label_map)) |dw_bc| {
            is_do_while = true;
            bc_idx = dw_bc;
            cond_start = null;
        } else {
            // Pattern A: separate top-test condition block.
            const cond_lbl = next_inst.words[1];
            const cond_idx = label_map.get(cond_lbl) orelse {
                if (label_map.get(merge_lbl)) |mi| return mi;
                return loop_idx + 1;
            };
            cond_start = cond_idx + 1;
            bc_idx = cond_idx + 1;
            while (bc_idx < m.instructions.len) : (bc_idx += 1) {
                const scan = m.instructions[bc_idx];
                if (scan.op == .BranchConditional) break;
                if (scan.op == .Branch or scan.op == .FunctionEnd or scan.op == .Label) { bc_idx = m.instructions.len; break; }
            }
            if (bc_idx >= m.instructions.len) {
                if (label_map.get(merge_lbl)) |mi| return mi;
                return loop_idx + 1;
            }
            cond_end = bc_idx;
        }
    } else if (next_inst.op == .BranchConditional and next_inst.words.len >= 4) {
        // Pattern B: BranchConditional directly after LoopMerge
        bc_idx = loop_idx + 1;
        cond_start = null;
        cond_end = loop_idx + 1;
    } else {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    const bc = m.instructions[bc_idx];
    if (bc.words.len < 4) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    var body_lbl = bc.words[2];

    // #246: do-while emission.
    //  - STRAIGHT-LINE body  → keep the existing `while(true){ body; if(!cond)break; }`.
    //  - body WITH control flow (if/continue/break) → emit a NATIVE `do { body }
    //    while(<inlined cond>);`, IF the back-edge condition can be rebuilt as an inline
    //    expression over persistent vars (so a body `continue` re-evaluates it at the
    //    bottom test, and the controlling expression — which is outside the body block
    //    scope — references no body-local temp). Otherwise honest-error as before.
    var body_has_cf = false;
    var dw_inlined: ?[]const u8 = null;
    if (is_do_while) {
        body_lbl = next_inst.words[1]; // OpBranch target = body
        dw_loop_when_true = (bc.words[2] == header_lbl);

        const bidx = label_map.get(body_lbl) orelse m.instructions.len;
        var sidx = bidx + 1;
        while (sidx < m.instructions.len) : (sidx += 1) {
            const t = m.instructions[sidx];
            if (t.op == .Label and t.words.len > 1 and t.words[1] == cont_lbl) break;
            if (t.op == .FunctionEnd) break;
            // Nested loop or switch sharing the do-while condition is not yet supported.
            if (t.op == .LoopMerge or t.op == .Switch) return error.UnstructuredControlFlow;
            // if/continue/break in the body — supported via the native do-while path.
            if (t.op == .SelectionMerge or t.op == .BranchConditional) body_has_cf = true;
            // A branch to anything other than the continue (back-edge) or the merge
            // (a `break`) is unstructured for THIS flat scan — fail loud. NOTE: this is
            // intentionally conservative — the scan is not block-nesting-aware, so a
            // structured `if (a) { b(); }` whose then-block falls through to its own
            // selection-merge (a `Branch %sel_merge`) is rejected here even though the
            // body emitter could render it. Only trivial `if(c) continue;`/`break;`
            // bodies are accepted in this first increment; richer bodies honest-error.
            if (t.op == .Branch and t.words.len > 1 and t.words[1] != cont_lbl and t.words[1] != merge_lbl) return error.UnstructuredControlFlow;
        }
        if (body_has_cf) {
            // Native do-while requires the condition rebuilt over persistent vars.
            dw_inlined = tryInlineDoWhileCond(m, names, bc.words[1], alloc) orelse return error.UnstructuredControlFlow;
        }
    }
    const dw_native = dw_inlined != null;

    // #237: run the SSA phi counter update at the TOP of the loop (guarded by a
    // first-iteration flag) so a `continue` — which skips the bottom-of-loop update
    // in `while(true)` — still advances the counter, matching a real `for` loop.
    var fbuf: [40]u8 = undefined;
    const first_flag = std.fmt.bufPrint(&fbuf, "_loopfirst_{d}", .{loop_idx}) catch "_loopfirst";
    // do-while loops carry their update in the body and test at the bottom; the
    // #237 top-of-loop transform does not apply.
    const has_phis = !is_do_while and (if (g_loop_phis) |lp| (if (lp.get(loop_idx)) |pl| pl.items.len > 0 else false) else false);
    if (has_phis) try w.print("    bool {s} = true;\n", .{first_flag});

    if (dw_native) {
        try w.writeAll("    do\n    {\n");
    } else {
        try w.writeAll("    while (true)\n    {\n");
    }

    if (has_phis) {
        try w.print("        if (!{s})\n        {{\n", .{first_flag});
        const cont_idx0 = label_map.get(cont_lbl) orelse m.instructions.len;
        if (cont_idx0 < m.instructions.len) {
            var ci0: usize = cont_idx0 + 1;
            while (ci0 < m.instructions.len) : (ci0 += 1) {
                const cinst = m.instructions[ci0];
                if (cinst.op == .FunctionEnd or cinst.op == .Label or cinst.op == .Branch) break;
                if (cinst.op == .LoopMerge or cinst.op == .SelectionMerge) continue;
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid);
            }
        }
        if (g_loop_phis) |lp| {
            if (lp.get(loop_idx)) |plist| {
                for (plist.items) |pi| {
                    const rname = names.get(pi.result_id) orelse continue;
                    const vname = names.get(pi.update_id) orelse continue;
                    if (std.mem.eql(u8, rname, vname)) continue;
                    try w.print("        {s} = {s};\n", .{ rname, vname });
                }
            }
        }
        try w.writeAll("        }\n");
        try w.print("        {s} = false;\n", .{first_flag});
    }

    var cond_name: []const u8 = names.get(bc.words[1]) orelse "true";
    if (cond_start) |cs| {
        if (cs < cond_end) {
            var ci: usize = cs;
            while (ci < cond_end) : (ci += 1) {
                const cinst = m.instructions[ci];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid);
            }
        }
    } else {
        // Pattern B: the condition is computed in the HEADER block (deferred by the
        // caller). Replay the header's non-phi instructions HERE so the comparison
        // re-evaluates against the live loop counter each iteration.
        var hlabel: usize = loop_idx;
        while (hlabel > 0) : (hlabel -= 1) {
            if (m.instructions[hlabel].op == .Label) break;
        }
        var hp = hlabel + 1;
        while (hp < loop_idx) : (hp += 1) {
            const hinst = m.instructions[hp];
            if (hinst.op == .Phi or hinst.op == .Label or hinst.op == .SelectionMerge or hinst.op == .LoopMerge or hinst.op == .Branch or hinst.op == .BranchConditional) continue;
            try emitInstruction(m, names, decs, hinst, w, alloc, is_frag, ovid);
        }
        cond_name = names.get(bc.words[1]) orelse cond_name;
    }
    if (!is_do_while) try w.print("        if (!({s})) break;\n", .{cond_name}); // top-test only
    const body_idx = label_map.get(body_lbl) orelse m.instructions.len;
    if (body_idx < m.instructions.len) {
        var bi: usize = body_idx + 1;
        while (bi < m.instructions.len) : (bi += 1) {
            const binst = m.instructions[bi];
            if (binst.op == .FunctionEnd) break;
            if (isDeferredHdrGLSL(bi)) continue;
            if (try tryEmitLoopPhiDeclGLSL(m, names, binst, w, alloc, "        ")) continue;
            if (binst.op == .Label and binst.words.len > 1) {
                const lbl = binst.words[1];
                if (lbl == cont_lbl or lbl == merge_lbl) break;
                continue;
            }
            if (binst.op == .LoopMerge) {
                // Nested loop — recurse
                if (binst.words.len >= 3) {
                    const nmerge = binst.words[1];
                    const ncont = binst.words[2];
                    bi = try emitWhileLoop(m, names, decs, bi, nmerge, ncont, label_map, bc_merge, w, alloc, is_frag, ovid);
                    bi -= 1; // caller will increment
                }
                continue;
            }
            if (binst.op == .SelectionMerge) continue;
            if (binst.op == .Branch) {
                if (binst.words.len > 1 and (binst.words[1] == cont_lbl or binst.words[1] == merge_lbl)) continue;
                continue;
            }
            if (binst.op == .BranchConditional) {
                const ncn = names.get(binst.words[1]) orelse "c";
                const ntl = binst.words[2];
                const nfl = if (binst.words.len > 3) binst.words[3] else null;
                const nml = bc_merge.get(bi);
                // Check if true/false labels are trivial continue/break (just a Label + Branch to cont_lbl/merge_lbl)
                const tl_is_trivial_continue = blk: { if (ntl == cont_lbl) break :blk true; const tli = label_map.get(ntl) orelse break :blk false; if (tli + 2 < m.instructions.len and m.instructions[tli].op == .Label and m.instructions[tli + 1].op == .Branch and m.instructions[tli + 1].words.len > 1 and m.instructions[tli + 1].words[1] == cont_lbl) break :blk true; break :blk false; };
                const fl_is_trivial_continue = blk: { if (nfl == null) break :blk false; if (nfl.? == cont_lbl) break :blk true; const fli = label_map.get(nfl.?) orelse break :blk false; if (fli + 2 < m.instructions.len and m.instructions[fli].op == .Label and m.instructions[fli + 1].op == .Branch and m.instructions[fli + 1].words.len > 1 and m.instructions[fli + 1].words[1] == cont_lbl) break :blk true; break :blk false; };
                const tl_is_trivial_break = blk: { if (ntl == merge_lbl) break :blk true; const tli2 = label_map.get(ntl) orelse break :blk false; if (tli2 + 2 < m.instructions.len and m.instructions[tli2].op == .Label and m.instructions[tli2 + 1].op == .Branch and m.instructions[tli2 + 1].words.len > 1 and m.instructions[tli2 + 1].words[1] == merge_lbl) break :blk true; break :blk false; };
                const fl_is_trivial_break = blk: { if (nfl == null) break :blk false; if (nfl.? == merge_lbl) break :blk true; const fli2 = label_map.get(nfl.?) orelse break :blk false; if (fli2 + 2 < m.instructions.len and m.instructions[fli2].op == .Label and m.instructions[fli2 + 1].op == .Branch and m.instructions[fli2 + 1].words.len > 1 and m.instructions[fli2 + 1].words[1] == merge_lbl) break :blk true; break :blk false; };
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    if (tl_is_trivial_continue and (fl_is_trivial_break or !nhe)) {
                        // if (cond) continue;
                        try w.print("        if ({s}) continue;\n", .{ncn});
                    } else if (tl_is_trivial_break and fl_is_trivial_continue) {
                        // if (cond) break; else continue;
                        try w.print("        if ({s}) break;\n", .{ncn});
                        try w.writeAll("        continue;\n");
                    } else if (tl_is_trivial_continue and nhe) {
                        // if (cond) continue; else { ... }
                        try w.print("        if ({s}) continue;\n", .{ncn});
                        bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                    } else if (tl_is_trivial_break) {
                        // if (cond) break;
                        try w.print("        if ({s}) break;\n", .{ncn});
                        if (nhe) {
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        }
                    } else if (fl_is_trivial_continue) {
                        // if (cond) { ... } else continue;
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        try w.writeAll("        } continue;\n");
                    } else if (fl_is_trivial_break and !nhe) {
                        // if (cond) { ... } else break; (no else = merge == false label)
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        try w.writeAll("        }\n");
                    } else {
                        // General case
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        if (nhe) {
                            try w.writeAll("        } else {\n");
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        }
                        try w.writeAll("        }\n");
                    }
                    if (label_map.get(nmv)) |nmi| { bi = nmi; }
                }
                continue;
            }
            if (binst.op == .Switch) {
                if (binst.words.len < 3) continue;
                const sn = names.get(binst.words[1]) orelse "s";
                const dl = binst.words[2];
                const sml = bc_merge.get(bi);
                if (sml) |smv| {
                    try w.print("        switch ({s}) {{\n", .{sn});
                    if (dl != smv) {
                        try w.writeAll("        default:\n");
                        bi = try emitBlock(m, names, decs, dl, smv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", true);
                    }
                    var wi: usize = 3;
                    while (wi + 1 < binst.words.len) : (wi += 2) {
                        const cv = binst.words[wi];
                        const target = binst.words[wi + 1];
                        if (target == smv) continue;
                        try w.print("        case {d}:\n", .{cv});
                        bi = try emitBlock(m, names, decs, target, smv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", true);
                    }
                    try w.writeAll("        }\n");
                    if (label_map.get(smv)) |smi| { bi = smi; }
                }
                continue;
            }
            try emitInstruction(m, names, decs, binst, w, alloc, is_frag, ovid);
        }
    }
    // Emit continue block (e.g., i++ in for-loops). For phi-counter loops the
    // update + write-back were hoisted to the top (#237), so skip them here. For the
    // native do-while (#246) the latch block IS the condition, rebuilt inline below —
    // its instructions must NOT be emitted as body statements.
    if (!has_phis and !dw_native) {
        const cont_idx = label_map.get(cont_lbl) orelse m.instructions.len;
        if (cont_idx < m.instructions.len) {
            var ci2: usize = cont_idx + 1;
            while (ci2 < m.instructions.len) : (ci2 += 1) {
                const cinst = m.instructions[ci2];
                if (cinst.op == .FunctionEnd) break;
                if (cinst.op == .Label) break;
                if (cinst.op == .Branch) break;
                if (cinst.op == .BranchConditional) break; // do-while back-edge — handled below
                if (cinst.op == .LoopMerge or cinst.op == .SelectionMerge) continue;
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid);
            }
        }
    }
    if (dw_native) {
        // Native do-while (#246): close with the inlined back-edge condition. A body
        // `continue` lands here (do-while continue semantics); the condition reads the
        // persistent loop vars, so it re-evaluates correctly each iteration.
        const cond = dw_inlined.?;
        if (dw_loop_when_true) {
            try w.print("    }} while ({s});\n", .{cond});
        } else {
            try w.print("    }} while (!({s}));\n", .{cond});
        }
    } else {
        // do-while (pattern C, straight-line body): test the back-edge condition at the
        // BOTTOM of a while(true) loop.
        if (is_do_while) {
            const dwc = names.get(bc.words[1]) orelse "true";
            if (dw_loop_when_true) {
                try w.print("        if (!({s})) break;\n", .{dwc});
            } else {
                try w.print("        if ({s}) break;\n", .{dwc});
            }
        }
        try w.writeAll("    }\n");
    }
    if (label_map.get(merge_lbl)) |mi| return mi;
    return loop_idx + 1;
}


fn emitBlock(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    label: u32, merge_label: u32,
    lm: *const std.AutoHashMap(u32, usize),
    bm: *const std.AutoHashMap(usize, u32),
    w: anytype, alloc: std.mem.Allocator,
    is_frag: bool, ovid: ?u32, indent: []const u8,
    is_switch: bool,
) anyerror!usize {
    const si = lm.get(label) orelse return error.InvalidSpirv;
    var i: usize = si + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) break;
        // A loop nested in this if/switch branch: handle its header phi / deferred
        // condition exactly as the top-level path does.
        if (isDeferredHdrGLSL(i)) continue;
        if (inst.op == .Phi) {
            const phi_indent = std.fmt.allocPrint(alloc, "{s}    ", .{indent}) catch indent;
            defer if (phi_indent.ptr != indent.ptr) alloc.free(phi_indent);
            if (try tryEmitLoopPhiDeclGLSL(m, names, inst, w, alloc, phi_indent)) continue;
        }
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == merge_label) {
            if (is_switch) try w.print("{s}    break;\n", .{indent});
            break;
        }
        if (inst.op == .Label or inst.op == .SelectionMerge) continue;
        if (inst.op == .LoopMerge) {
            if (inst.words.len >= 3) {
                const nmerge = inst.words[1];
                const ncont = inst.words[2];
                i = try emitWhileLoop(m, names, decs, i, nmerge, ncont, lm, bm, w, alloc, is_frag, ovid);
                i -= 1;
            }
            continue;
        }
        if (inst.op == .Branch) {
            if (is_switch) try w.print("{s}    break;\n", .{indent});
            break;
        }
        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const nm = bm.get(i);
            if (nm) |nmv| {
                const he = fl != null and fl.? != nmv;
                // Scan merge block for Phi nodes to pre-declare
                const merge_idx2 = lm.get(nmv) orelse m.instructions.len;
                var phi_decls2 = std.ArrayList(struct { result_id: u32, type_id: u32, vals: [2]u32, preds: [2]u32 }).initCapacity(alloc, 4) catch unreachable;
                defer phi_decls2.deinit(alloc);
                if (merge_idx2 < m.instructions.len) {
                    var mi3: usize = merge_idx2 + 1;
                    while (mi3 < m.instructions.len) : (mi3 += 1) {
                        const minst = m.instructions[mi3];
                        if (minst.op != .Phi) break;
                        if (minst.words.len >= 7) {
                            phi_decls2.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
                        }
                    }
                }
                for (phi_decls2.items) |pv| {
                    const rtt = glslType(m, pv.type_id, names, alloc) catch "float";
                    const vn = names.get(pv.result_id) orelse "pv";
                    try w.print("{s}    {s} {s}_phi;\n", .{ indent, rtt, vn });
                }
                try w.print("{s}    if ({s})\n{s}    {{\n", .{ indent, cn, indent });
                i = try emitBlock(m, names, decs, tl, nmv, lm, bm, w, alloc, is_frag, ovid, indent, false);
                for (phi_decls2.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const true_val = if (pv.preds[1] == tl) pv.vals[1] else pv.vals[0];
                    const tvn = exprName(m, names, true_val, alloc);
                    try w.print("{s}        {s}_phi = {s};\n", .{ indent, vn, tvn });
                }
                if (he) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent, false);
                    for (phi_decls2.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const false_val = if (pv.preds[1] != tl) pv.vals[1] else pv.vals[0];
                        const fvn = exprName(m, names, false_val, alloc);
                        try w.print("{s}        {s}_phi = {s};\n", .{ indent, vn, fvn });
                    }
                }
                try w.print("{s}    }}\n", .{indent});
                for (phi_decls2.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                    if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                }
                if (lm.get(nmv)) |nmi| { i = nmi; }
            } else {
                try w.print("{s}    if ({s}) {{ /* */ }}\n", .{ indent, cn });
            }
            continue;
        }
        if (inst.op == .Switch) {
            if (inst.words.len < 3) continue;
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const sml = bm.get(i);
            if (sml) |smv| {
                try w.print("{s}    switch ({s}) {{\n", .{ indent, sn });
                if (dl != smv) {
                    try w.print("{s}    default:\n", .{indent});
                    i = try emitBlock(m, names, decs, dl, smv, lm, bm, w, alloc, is_frag, ovid, indent, true);
                }
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == smv) continue;
                    try w.print("{s}    case {d}:\n", .{ indent, cv });
                    i = try emitBlock(m, names, decs, target, smv, lm, bm, w, alloc, is_frag, ovid, indent, true);
                }
                try w.print("{s}    }}\n", .{indent});
                if (lm.get(smv)) |smi| { i = smi; }
            } else {
                // No merge info for switch — try to find convergence
                var switch_merge2: ?u32 = null;
                if (inst.words.len >= 5) {
                    const fct = inst.words[4];
                    const fci = lm.get(fct) orelse fct;
                    var sci: usize = fci;
                    while (sci < m.instructions.len) : (sci += 1) {
                        const sinst = m.instructions[sci];
                        if (sinst.op == .Branch and sinst.words.len > 1) {
                            switch_merge2 = sinst.words[1];
                            break;
                        }
                        if (sinst.op == .ReturnValue or sinst.op == .Return or sinst.op == .Kill) break;
                        if (sinst.op == .BranchConditional) break;
                    }
                }
                if (switch_merge2) |sm2| {
                    try w.print("{s}switch ({s}) {{\n", .{ indent, sn });
                    if (dl != sm2) {
                        try w.print("{s}default:\n", .{indent});
                        i = try emitBlock(m, names, decs, dl, sm2, lm, bm, w, alloc, is_frag, ovid, indent, true);
                    }
                    var wi: usize = 3;
                    while (wi + 1 < inst.words.len) : (wi += 2) {
                        const cv = inst.words[wi];
                        const target = inst.words[wi + 1];
                        if (target == sm2) continue;
                        try w.print("{s}case {d}:\n", .{ indent, cv });
                        i = try emitBlock(m, names, decs, target, sm2, lm, bm, w, alloc, is_frag, ovid, indent, true);
                    }
                    try w.print("{s}}}\n", .{indent});
                    if (lm.get(sm2)) |smi| { i = smi; }
                } else {
                    try w.writeAll("    // switch: no merge info\n");
                }
            }
            continue;
        }
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
    }
    return i;
}


fn emitInstruction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    inst: Instruction,
    w: anytype, alloc: std.mem.Allocator,
    is_frag: bool, ovid: ?u32,
) !void {
    _ = decs;
    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output and is_frag) {
                const ri = inst.words[2];
                const tn = try glslType(m, inst.words[1], names, alloc);
                const arr_suffix = try getArraySuffix(m, inst.words[1]);
                try w.print("    {s} {s}{s};\n", .{ tn, names.get(ri) orelse "var", arr_suffix });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant or sc == .Workgroup) return;
            const ri = inst.words[2];
            const tn = try glslType(m, inst.words[1], names, alloc);
            const arr_suffix = try getArraySuffix(m, inst.words[1]);
            try w.print("    {s} {s}{s};\n", .{ tn, names.get(ri) orelse "var", arr_suffix });
        },
        .Load => {
            const rn = names.get(inst.words[2]) orelse "v";
            const pid = inst.words[3];
            const pn = names.get(pid) orelse "var";
            const pi = getDef(m, pid);
            var is_tex = false;
            var is_oload = false;
            if (pi) |p| {
                if (p.op == .Variable and p.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(p.words[3]);
                    if (sc == .UniformConstant) {
                        const pt = getDef(m, p.words[1]);
                        if (pt) |ptv| {
                            if (ptv.op == .TypePointer and ptv.words.len > 3) {
                                const pe = getDef(m, ptv.words[3]);
                                if (pe) |pev| {
                                    if (pev.op == .TypeSampler or pev.op == .TypeSampledImage or pev.op == .TypeImage) is_tex = true;
                                }
                            }
                        }
                    }
                    if (sc == .Output and is_frag) is_oload = true;
                    if (sc == .Input and is_frag) is_oload = true;
                }
            }
            // A load whose RESULT type is opaque (sampler/image) — e.g. an element
            // of a sampler ARRAY accessed via OpAccessChain (`tex[2]`) — passes the
            // access expression straight through as the sampler for `texture(...)`,
            // exactly like a scalar sampler load. Without this the element is wrongly
            // materialized into a `vec4` temp.
            if (!is_tex) {
                if (getDef(m, inst.words[1])) |ltv| {
                    if (ltv.op == .TypeSampledImage or ltv.op == .TypeSampler or ltv.op == .TypeImage) is_tex = true;
                }
            }
            if (is_oload or is_tex) {
                const a = try alloc.dupe(u8, pn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                const rtt = try glslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = ", .{ rtt, rn });
                try writeResolvePointer(m, names, pid, w);
                try w.writeAll(";\n");
            }
        },
        .Store => {
            if (inst.words.len < 3) return;
            const on = names.get(inst.words[2]) orelse "0";
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], w);
            try w.print(" = {s};\n", .{on});
        },
        .CopyObject => {
            if (inst.words.len < 4) return;
            const sn = names.get(inst.words[3]) orelse "0";
            const a = try alloc.dupe(u8, sn);
            if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
        },
        .CopyMemory => {
            if (inst.words.len < 3) return;
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], w);
            try w.writeAll(" = ");
            try writeResolvePointer(m, names, inst.words[2], w);
            try w.writeAll(";\n");
        },
        .Phi => {
            // If this Phi was already handled by emitBlock (name ends with _phi), skip
            if (names.get(inst.words[2])) |existing| {
                if (std.mem.endsWith(u8, existing, "_phi")) return;
            }
            if (inst.words.len < 4) return;
            const fv = inst.words[3];
            const result_id = inst.words[2];
            if (names.get(fv)) |sn| {
                const a = try alloc.dupe(u8, sn);
                if (names.fetchPut(result_id, a) catch null) |old| alloc.free(old.value);
            } else {
                const a = try std.fmt.allocPrint(alloc, "v{d}", .{fv});
                if (names.fetchPut(result_id, a) catch null) |old| alloc.free(old.value);
            }
        },
        .AccessChain => {
            const ri = inst.words[2];
            const bi = inst.words[3];
            const ex = try buildAccessExpr(m, names, bi, inst.words[4..], alloc);
            if (names.fetchPut(ri, ex) catch null) |old| alloc.free(old.value);
        },
        .FAdd, .IAdd => try emitBinOp(m, names, inst, "+", w, alloc),
        .FSub, .ISub => try emitBinOp(m, names, inst, "-", w, alloc),
        .FMul, .IMul => try emitBinOp(m, names, inst, "*", w, alloc),
        .FDiv, .SDiv, .UDiv => try emitBinOp(m, names, inst, "/", w, alloc),
        .FMod, .FRem => {
            // GLSL float modulo uses mod() function, not % operator
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = mod({s}, {s});\n", .{
                rtt,
                names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "a",
                names.get(inst.words[4]) orelse "b",
            });
        },
        .UMod, .SRem, .SMod => try emitBinOp(m, names, inst, "%", w, alloc),
        .FNegate, .SNegate => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try emitBinOp(m, names, inst, "*", w, alloc),
        .Dot => try emitCall(m, names, inst, "dot", w, alloc),
        .Transpose => try emitCall(m, names, inst, "transpose", w, alloc),
        .FOrdEqual, .FUnordEqual, .IEqual => try emitBinOp(m, names, inst, "==", w, alloc),
        .FOrdNotEqual, .FUnordNotEqual, .INotEqual => try emitBinOp(m, names, inst, "!=", w, alloc),
        .FOrdLessThan, .FUnordLessThan, .SLessThan, .ULessThan => try emitBinOp(m, names, inst, "<", w, alloc),
        .FOrdGreaterThan, .FUnordGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(m, names, inst, ">", w, alloc),
        .FOrdLessThanEqual, .FUnordLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(m, names, inst, "<=", w, alloc),
        .FOrdGreaterThanEqual, .FUnordGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(m, names, inst, ">=", w, alloc),
        .LogicalOr => try emitBinOp(m, names, inst, "||", w, alloc),
        .LogicalAnd => try emitBinOp(m, names, inst, "&&", w, alloc),
        .IsNan => try emitCall(m, names, inst, "isnan", w, alloc),
        .IsInf => try emitCall(m, names, inst, "isinf", w, alloc),
        .LogicalNot => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .Select => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const cond_name = names.get(inst.words[3]) orelse "c";
            const true_name = names.get(inst.words[4]) orelse "t";
            const false_name = names.get(inst.words[5]) orelse "f";
            // Check if condition is a bvec (vector boolean) — GLSL can't use ternary with bvec
            // Look up condition's result type to determine if it's bvecN
            const is_bvec = blk: {
                const cond_def = getDef(m, inst.words[3]);
                if (cond_def) |cd| {
                    if (cd.words.len > 1) {
                        const cond_type_str = glslType(m, cd.words[1], names, alloc) catch "bool";
                        break :blk std.mem.startsWith(u8, cond_type_str, "bvec");
                    }
                }
                break :blk false;
            };
            if (is_bvec) {
                // mix(false_val, true_val, bvec_condition) — GLSL mix with bvec selector
                try w.print("    {s} {s} = mix({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", false_name, true_name, cond_name });
            } else {
                try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", cond_name, true_name, false_name });
            }
        },
        .BitwiseOr => try emitBinOp(m, names, inst, "|", w, alloc),
        .BitwiseXor => try emitBinOp(m, names, inst, "^", w, alloc),
        .BitwiseAnd => try emitBinOp(m, names, inst, "&", w, alloc),
        .ShiftRightLogical, .ShiftRightArithmetic => try emitBinOp(m, names, inst, ">>", w, alloc),
        .ShiftLeftLogical => try emitBinOp(m, names, inst, "<<", w, alloc),
        .Not => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ~{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitReverse => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = bitfieldReverse({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitCount => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = bitCount({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        // OpBitFieldInsert: base, insert, offset, count → GLSL bitfieldInsert(base, insert, offset, bits).
        .BitFieldInsert => {
            if (inst.words.len < 7) return;
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = bitfieldInsert({s}, {s}, {s}, {s});\n", .{
                rtt,                                  names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0",  names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0",  names.get(inst.words[6]) orelse "0",
            });
        },
        // OpBitFieldSExtract / OpBitFieldUExtract: value, offset, count → bitfieldExtract
        // (overloaded by the value's signedness, so a single GLSL builtin covers both).
        .BitFieldSExtract, .BitFieldUExtract => {
            if (inst.words.len < 6) return;
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = bitfieldExtract({s}, {s}, {s});\n", .{
                rtt,                                  names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0",  names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0",
            });
        },
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU, .UConvert, .SConvert, .FConvert, .Bitcast => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        .CompositeConstruct => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[3..], 0..) |cid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(cid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .CompositeExtract => {
            // Skip if source is a decomposed std450 struct (FrexpStruct/ModfStruct)
            if (inst.words.len > 3) {
                const src_def = getDef(m, inst.words[3]);
                if (src_def) |sd| {
                    if (sd.op == .ExtInst and sd.words.len >= 5) {
                        const ext_op = sd.words[4];
                        if (ext_op == 52 or ext_op == 36) return; // FrexpStruct/ModfStruct - already decomposed
                    }
                }
            }
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{ rtt, names.get(inst.words[2]) orelse "v", comp });
            const pt = getTypeOf(m, inst.words[3]);
            var cur_type = pt;
            for (inst.words[4..]) |index| {
                const is_vec = if (cur_type) |ptv| blk: {
                    const pti = getDef(m, ptv);
                    break :blk pti != null and pti.?.op == .TypeVector;
                } else false;
                const is_struct = if (cur_type) |ptv| blk: {
                    const pti = getDef(m, ptv);
                    break :blk pti != null and pti.?.op == .TypeStruct;
                } else false;
                if (is_vec) {
                    try w.writeAll(swizzleChar(index));
                    // Update cur_type to element type
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| cur_type = tinst.words[2];
                    }
                } else if (is_struct) {
                    var mname_buf: [32]u8 = undefined;
                    const mname = getMemberName(m, cur_type.?, index, &mname_buf);
                    try w.print(".{s}", .{mname});
                    // Update cur_type to member type
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| {
                            if (index + 2 < tinst.words.len) cur_type = tinst.words[index + 2];
                        }
                    }
                } else {
                    try w.print("[{d}]", .{index});
                    // Update cur_type for matrix/array
                    if (cur_type) |ptv| {
                        const pti = getDef(m, ptv);
                        if (pti) |tinst| cur_type = tinst.words[2];
                    }
                }
            }
            try w.writeAll(";\n");
        },
        .CompositeInsert => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rname = names.get(inst.words[2]) orelse "v";
            const object = names.get(inst.words[3]) orelse "obj";
            const composite = names.get(inst.words[4]) orelse "comp";
            try w.print("    {s} {s} = {s};\n", .{ rtt, rname, composite });
            const pt = getTypeOf(m, inst.words[4]);
            const is_vec = if (pt) |ptv| blk: {
                const pti = getDef(m, ptv);
                break :blk pti != null and pti.?.op == .TypeVector;
            } else false;
            try w.print("    {s}", .{rname});
            for (inst.words[5..]) |index| {
                if (is_vec) {
                    try w.writeAll(swizzleChar(index));
                } else {
                    try w.print("[{d}]", .{index});
                }
            }
            try w.print(" = {s};\n", .{object});
        },
        .VectorShuffle => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "v1";
            const v2 = names.get(inst.words[4]) orelse "v2";
            const v1t = getTypeOf(m, inst.words[3]);
            const v1l: u32 = if (v1t) |vt| blk: {
                const vi = getDef(m, vt);
                break :blk if (vi != null and vi.?.op == .TypeVector) vi.?.words[3] else 4;
            } else 4;
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[5..], 0..) |sel, i| {
                if (i > 0) try w.writeAll(", ");
                if (sel < v1l) {
                    try w.print("{s}{s}", .{ v1, swizzleChar(sel) });
                } else {
                    try w.print("{s}{s}", .{ v2, swizzleChar(sel - v1l) });
                }
            }
            try w.writeAll(");\n");
        },
        .DPdx, .DPdxFine, .DPdxCoarse => try emitCall(m, names, inst, "dFdx", w, alloc),
        .DPdy, .DPdyFine, .DPdyCoarse => try emitCall(m, names, inst, "dFdy", w, alloc),
        .Fwidth, .FwidthFine, .FwidthCoarse => try emitCall(m, names, inst, "fwidth", w, alloc),
        .All => try emitCall(m, names, inst, "all", w, alloc),
        .Any => try emitCall(m, names, inst, "any", w, alloc),
        .ExtInst => {
            if (inst.words.len < 5) return;
            const std450_opcode = inst.words[4];
            // FrexpStruct (52) and ModfStruct (36) return structs that can't be emitted as GLSL types.
            // Decompose into: pre-declare out param; result = func(input, out_param);
            if (std450_opcode == 52 or std450_opcode == 36) {
                const result_id = inst.words[2];
                const input_name = names.get(inst.words[5]) orelse "x";
                const func_name: []const u8 = if (std450_opcode == 52) "frexp" else "modf";
                // Find downstream CompositeExtracts that reference our result_id
                // Extract member 0 (fract) and member 1 (exp/whole) result names
                var fract_name: []const u8 = "_fract";
                var second_name: []const u8 = "_second";
                var fract_type: []const u8 = "float";
                var second_type: []const u8 = "int"; // frexp: int for exp; modf: float for whole
                {
                    // Find our position by searching for our result_id definition
                    var j: usize = 0;
                    for (m.instructions, 0..) |mi, i| {
                        if (mi.op == .ExtInst and mi.words.len >= 3 and mi.words[2] == result_id) {
                            j = i + 1;
                            break;
                        }
                    }
                    while (j < m.instructions.len) : (j += 1) {
                        const ni = m.instructions[j];
                        if (ni.op == .FunctionEnd) break;
                        if (ni.op == .CompositeExtract and ni.words.len >= 5 and ni.words[3] == result_id) {
                            const member_idx = ni.words[4]; // which member (0 or 1)
                            const ce_result = ni.words[2];
                            const ce_name = names.get(ce_result) orelse "v";
                            const ce_type = try glslType(m, ni.words[1], names, alloc);
                            if (member_idx == 0) {
                                fract_name = ce_name;
                                fract_type = ce_type;
                            } else if (member_idx == 1) {
                                second_name = ce_name;
                                second_type = ce_type;
                            }
                        }
                    }
                }
                // Emit: <second_type> <second_name>; <fract_type> <fract_name> = <func>(<input>, <second_name>);
                try w.print("    {s} {s};\n", .{ second_type, second_name });
                try w.print("    {s} {s} = {s}({s}, {s});\n", .{ fract_type, fract_name, func_name, input_name, second_name });
            } else {
                try emitStd450(m, names, inst, std450_opcode, w, alloc);
            }
        },
        .SampledImage => {
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
        },
        .OpImage => {
            // OpImage extracts image from sampled_image — in GLSL, combined sampler is passed directly
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
        },
        .ImageSampleImplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            try w.print("    {s} {s} = texture({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
        },
        .ImageSampleDrefImplicitLod => {
            // Shadow texture: texture(sampler2DShadow, vec3(uv, depth))
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = texture({s}, vec3({s}, {s}));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dref });
        },
        .ImageSampleDrefExplicitLod => {
            // Shadow texture with explicit LOD
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = textureLod({s}, vec4({s}, {s}, 0.0), 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dref });
        },
        .ImageSampleProjImplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // Projected: textureProj(sampler, vec4(xy, z, w)) divides xy by w
            try w.print("    {s} {s} = textureProj({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
        },
        .ImageSampleProjDrefImplicitLod => {
            // Projected shadow: textureProj(sampler2DShadow, vec4(xy, depth, w))
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = textureProj({s}, vec4({s}.xy, {s}, {s}.w));\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dref, coord });
        },
        .ImageSampleProjDrefExplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = textureProjLod({s}, vec4({s}.xy, {s}, {s}.w), 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dref, coord });
        },
        .ImageSampleExplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    try w.print("    {s} {s} = textureLod({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[off]) orelse "0" });
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    try w.print("    {s} {s} = textureGrad({s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[off]) orelse "0", names.get(inst.words[off + 1]) orelse "0" });
                } else {
                    try w.print("    {s} {s} = textureLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
                }
            } else {
                try w.print("    {s} {s} = textureLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageSampleProjExplicitLod => {
            // Projected explicit LOD: textureProjLod(sampler, coord, lod)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    try w.print("    {s} {s} = textureProjLod({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[off]) orelse "0" });
                } else {
                    try w.print("    {s} {s} = textureProjLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
                }
            } else {
                try w.print("    {s} {s} = textureProjLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageFetch => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            // Check if the sampled image is a buffer texture (texelFetch takes 2 args for buffers)
            const is_buffer = blk: {
                const si_def = getDef(m, inst.words[3]);
                if (si_def) |sd| {
                    if (sd.op == .SampledImage and sd.words.len > 2) {
                        const img_def = getDef(m, sd.words[2]);
                        if (img_def) |id| {
                            if (id.op == .TypeImage and id.words.len > 3 and id.words[3] == 5) break :blk true;
                        }
                    }
                    // Also check direct image reference (OpImage result)
                    if (sd.op == .OpImage and sd.words.len > 1) {
                        const img_type_def = getDef(m, sd.words[1]);
                        if (img_type_def) |id| {
                            if (id.op == .TypeImage and id.words.len > 3 and id.words[3] == 5) break :blk true;
                        }
                    }
                }
                break :blk false;
            };
            if (is_buffer) {
                try w.print("    {s} {s} = texelFetch({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0" });
            } else {
                try w.print("    {s} {s} = texelFetch({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0" });
            }
        },
        .ImageGather => {
            // OpImageGather: result_type, result, sampled_image, coordinate, component [, image_operands]
            // textureGatherOffsets lowers to OpImageGather with the ConstOffsets
            // image operand (mask bit 0x20 at word[6], the 4-offset array id at
            // word[7]). GLSL *can* express textureGatherOffsets, but
            // reconstructing the offsets-array expression from the constant id is
            // out of scope for this round-trip backend; emitting a plain
            // textureGather would SILENTLY DROP the offsets (silent-wrong). Fail
            // loudly instead; textureGatherOffsets round-trip is a follow-up.
            if (inst.words.len > 6 and (inst.words[6] & 0x20) != 0) {
                return error.UnsupportedImageOperands;
            }
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const comp = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = textureGather({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, comp });
        },
        .ImageDrefGather => {
            // OpImageDrefGather: result_type, result, sampled_image, coordinate, dref [, image_operands]
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            try w.print("    {s} {s} = textureGather({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dref });
        },
        .ImageRead => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = imageLoad({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "img", names.get(inst.words[4]) orelse "0" });
        },
        .ImageWrite => {
            // OpImageWrite: image, coordinate, texel
            const img = names.get(inst.words[1]) orelse "img";
            const coord = names.get(inst.words[2]) orelse "0";
            const texel = names.get(inst.words[3]) orelse "vec4(0)";
            try w.print("    imageStore({s}, {s}, {s});\n", .{img, coord, texel});
        },
        .ImageQuerySizeLod => {
            // OpImageQuerySizeLod: result_type, result, image, lod
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const lod = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            try w.print("    {s} {s} = textureSize({s}, {s});\n", .{rtt, rn, img, lod});
        },
        .ImageQuerySize => {
            // OpImageQuerySize: result_type, result, image (no lod)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    {s} {s} = textureSize({s}, 0);\n", .{rtt, rn, img});
        },
        .ImageQueryLod => {
            // OpImageQueryLod: result_type, result, SampledImage, coord
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const coord2 = if (inst.words.len > 4) names.get(inst.words[4]) orelse "vec2(0)" else "vec2(0)";
            try w.print("    {s} {s} = textureQueryLod({s}, {s});\n", .{rtt, rn, img, coord2});
        },
        .ImageQueryLevels => {
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    int {s} = textureQueryLevels({s});\n", .{rn, img});
        },
        .ImageQuerySamples => {
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    int {s} = textureSamples({s});\n", .{rn, img});
        },
        .Kill => try w.writeAll("    discard;\n"),
        .Unreachable => {}, // no-op in GLSL
        .BeginInvocationInterlockEXT => try w.writeAll("    beginInvocationInterlockARB();\n"),
        .EndInvocationInterlockEXT => try w.writeAll("    endInvocationInterlockARB();\n"),
        .ReadClockKHR => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const scope_id = if (inst.words.len > 3) inst.words[3] else 0;
            const scope_name = if (scope_id == 1) "clockARB()" else "clockRealtimeEXT()";
            const rn = names.get(inst.words[2]) orelse "t";
            try w.print("    {s} {s} = {s};\n", .{ rtt, rn, scope_name });
        },
        .ControlBarrier => try w.writeAll("    barrier();\n    memoryBarrier();\n"),
        .ImageTexelPointer => {
            // No code emission needed — result used by atomic ops which resolve via classifyAtomicPtr
        },
        .MemoryBarrier => try w.writeAll("    memoryBarrier();\n"),
        .EmitVertex => try w.writeAll("    EmitVertex();\n"),
        .EndPrimitive => try w.writeAll("    EndPrimitive();\n"),

        // Atomic operations → GLSL atomic* builtins
        .AtomicIAdd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicISub => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, -{s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, -{s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicOr => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicOr({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicOr({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicXor => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicXor({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicXor({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicAnd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAnd({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicAnd({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicSMin, .AtomicUMin => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicMin({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicMin({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicSMax, .AtomicUMax => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicMax({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicMax({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicExchange => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicExchange({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicExchange({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },
        .AtomicCompareExchange => {
            // OpAtomicCompareExchange: result_type, result, pointer, scope, eq-sem,
            // uneq-sem, value(new/data), comparator(compare) — data=words[7], compare=words[8].
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
            const cmp = if (inst.words.len > 8) names.get(inst.words[8]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicCompSwap({s}, {s}, {s});\n", .{rtt, rn, ptr, cmp, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicCompSwap({s}, {s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, cmp, val}),
            }
        },
        .AtomicFAddEXT => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0.0" else "0.0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, {s});\n", .{rtt, rn, ptr, val}),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, {s});\n", .{rtt, rn, p.img, p.coord, val}),
            }
        },

        // Subgroup operations → GLSL subgroup* builtins
        .GroupNonUniformElect => {
            const rn = names.get(inst.words[2]) orelse "v";
            try w.print("    bool {s} = subgroupElect();\n", .{rn});
        },
        .GroupNonUniformAll => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAll({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformAny => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAny({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformAllEqual => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAllEqual({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBroadcast => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupBroadcast({s}, {s});\n", .{rtt, rn, val, lane});
        },
        .GroupNonUniformBroadcastFirst => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupBroadcastFirst({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBallot => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupBallot({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformShuffle => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffle({s}, {s});\n", .{rtt, rn, val, lane});
        },
        .GroupNonUniformShuffleXor => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const mask = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleXor({s}, {s});\n", .{rtt, rn, val, mask});
        },
        .GroupNonUniformShuffleUp => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleUp({s}, {s});\n", .{rtt, rn, val, delta});
        },
        .GroupNonUniformShuffleDown => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleDown({s}, {s});\n", .{rtt, rn, val, delta});
        },
        .GroupNonUniformIAdd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAdd({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformFAdd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAdd({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformIMul => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupMul({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformFMul => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupMul({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupMin({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupMax({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseAnd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAnd({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseOr => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupOr({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseXor => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupXor({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformLogicalAnd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAnd({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformLogicalOr => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupOr({s});\n", .{rtt, rn, val});
        },
        // SubgroupAllKHR / SubgroupAnyKHR
        .SubgroupAllKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = subgroupAll({s});\n", .{rn, val});
        },
        .SubgroupAnyKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = subgroupAny({s});\n", .{rn, val});
        },
        .Return => {
            if (!(is_frag and ovid != null)) try w.writeAll("    return;\n");
        },
        .ReturnValue => {
            const vid = inst.words[1];
            if (!(is_frag and ovid != null and vid == ovid.?)) {
                try w.print("    return {s};\n", .{names.get(vid) orelse "0"});
            }
        },
        .FunctionCall => {
            const cfid = inst.words[3];
            const cfn = names.get(cfid) orelse "func";
            const rn = names.get(inst.words[2]) orelse "v";
            const rti = inst.words[1];
            const is_void = blk: {
                const r = getDef(m, rti);
                break :blk r != null and r.?.op == .TypeVoid;
            };
            if (is_void) {
                try w.print("    {s}(", .{cfn});
            } else {
                const rtt = try glslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}(", .{ rtt, rn, cfn });
            }
            for (inst.words[4..], 0..) |aid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(aid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .ArrayLength => {
            // OpArrayLength %uint %result %structPtr <memberLiteral> → GLSL's native
            // `instance.member.length()`. The SSBO declaration now uses original member
            // names + `[]` (see emitStructMembers original_names path), so `B.d.length()`
            // matches the body access form. (#296; faithful GLSL for #294's OpArrayLength.)
            if (inst.words.len < 5) return error.UnsupportedOp;
            const rtt = try glslType(m, inst.words[1], names, alloc); // uint
            const rn = names.get(inst.words[2]) orelse return error.UnsupportedOp;
            const struct_ptr = inst.words[3];
            const member_idx = inst.words[4];
            const inst_name = names.get(struct_ptr) orelse return error.UnsupportedOp;
            // Resolve the struct type behind the variable's pointer; the structure operand
            // must be a direct OpVariable (not an access chain into an array-of-blocks etc.).
            const var_def = getDef(m, struct_ptr) orelse return error.UnsupportedOp;
            if (var_def.op != .Variable or var_def.words.len < 4) return error.UnsupportedOp;
            // The faithful `instance.member.length()` form is only valid when the SSBO is
            // actually DECLARED in the output, which happens only for the compute stage (the
            // SSBO emission loop is `is_compute`-gated). BOTH SSBO encodings now declare their
            // members by original name — StorageBuffer-class and old-style Uniform+BufferBlock
            // (the latter via isOldStyleSSBOVar) — so either is reconstructable here. Anything
            // else falls back to the honest error rather than reference an undeclared buffer.
            const sc: spirv.StorageClass = @enumFromInt(var_def.words[3]);
            const is_declared_ssbo = sc == .StorageBuffer or isOldStyleSSBOVar(m, struct_ptr);
            if (m.execution_model != .GLCompute or !is_declared_ssbo) return error.UnsupportedOp;
            const ptr_def = getDef(m, var_def.words[1]) orelse return error.UnsupportedOp;
            if (ptr_def.op != .TypePointer or ptr_def.words.len < 4) return error.UnsupportedOp;
            var mbuf: [32]u8 = undefined;
            const mname = getMemberName(m, ptr_def.words[3], member_idx, &mbuf);
            // An anonymous block exposes its members in global scope, so the runtime array is
            // referenced BARE (`count.length()`); prefixing the empty instance name yields a
            // leading-dot `.count.length()` that glslang rejects with "unexpected DOT" — the
            // same suppression the access-chain emitters apply via isAnonymousSSBOVar.
            const anon = isAnonymousSSBOVar(m, names, struct_ptr);
            // GLSL `.length()` yields `int`; OpArrayLength's result type is `uint`. Wrap so
            // the declared type matches without relying on an implicit int→uint conversion.
            if (anon)
                try w.print("    {s} {s} = {s}({s}.length());\n", .{ rtt, rn, rtt, mname })
            else
                try w.print("    {s} {s} = {s}({s}.{s}.length());\n", .{ rtt, rn, rtt, inst_name, mname });
        },
        else => {
            try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
        },
    }
}

fn emitBinOp(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s} {s} {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "a", op, names.get(inst.words[4]) orelse "b" });
}

fn emitCall(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[3..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}

/// Classify an atomic pointer: SSBO variable or ImageTexelPointer (image atomic)
const AtomicPtr = union(enum) {
    ssbo: []const u8,
    image: struct { img: []const u8, coord: []const u8 },
};

fn classifyAtomicPtr(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), ptr_id: u32) AtomicPtr {
    const pd = getDef(m, ptr_id);
    if (pd) |d| {
        if (d.op == .ImageTexelPointer) {
            return .{ .image = .{
                .img = names.get(d.words[3]) orelse "img",
                .coord = names.get(d.words[4]) orelse "0",
            } };
        }
    }
    return .{ .ssbo = names.get(ptr_id) orelse "mem" };
}

fn emitStd450(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, instruction: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const func = std450ToGlsl(instruction) orelse {
        try w.print("    // unhandled std450 #{d}\n", .{instruction});
        return;
    };
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[5..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}
