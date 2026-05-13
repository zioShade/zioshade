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
const TextureDecl = struct { name: []const u8, binding: u32 };

// ---- Helpers ----
fn getDef(m: *const ParsedModule, id: u32) ?Instruction { if (id >= m.id_defs.len) return null; const i = m.id_defs[id] orelse return null; if (i >= m.instructions.len) return null; return m.instructions[i]; }
fn getTypeOf(m: *const ParsedModule, id: u32) ?u32 { const inst = getDef(m, id) orelse return null; return switch (inst.op) { .TypeVoid,.TypeBool,.TypeInt,.TypeFloat,.TypeVector,.TypeMatrix,.TypeImage,.TypeSampler,.TypeSampledImage,.TypeArray,.TypeRuntimeArray,.TypeStruct,.TypePointer,.TypeFunction => null, else => if (inst.words.len > 1) inst.words[1] else null }; }
fn swizzleChar(i: u32) []const u8 { return switch(i){ 0=>".x",1=>".y",2=>".z",3=>".w",else=>".x"}; }
fn parseLitStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, words.len*4); for(words)|word|{const bytes:[4]u8=@bitCast(word);for(bytes)|c|{if(c==0)break;buf.appendAssumeCapacity(c);}} return buf.toOwnedSlice(alloc); }
fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, name.len); for(name)|c|{switch(c){'a'...'z','A'...'Z','0'...'9','_'=>buf.appendAssumeCapacity(c),else=>buf.appendAssumeCapacity('_'),}} return buf.toOwnedSlice(alloc); }
fn isUniformVar(m: *const ParsedModule, id: u32) bool { const inst = getDef(m, id) orelse return false; if (inst.op == .Variable and inst.words.len >= 4) { const sc: spirv.StorageClass = @enumFromInt(inst.words[3]); return sc == .Uniform; } return false; }

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

fn buildAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) return try alloc.dupe(u8, base_name);
    const base_is_cb = isUniformVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    // Use a stack buffer to avoid heap allocation for typical access chains
    var writer = compat.StackBufWriter(512).init();
    if (!base_is_cb) writer.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    writer.writeAll(swizzleChar(val));
                } else if (base_is_cb) {
                    writer.print("{s}_m{d}", .{cb_prefix, val});
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
    if (!base_is_cb) try buf.appendSlice(alloc, base_name);
    cur_type = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try buf.appendSlice(alloc, swizzleChar(val));
                } else if (base_is_cb) {
                    try buf.print(alloc, "{s}_m{d}", .{cb_prefix, val});
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
    const base_is_cb = isUniformVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    if (!base_is_cb) try w.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else if (base_is_cb) {
                    // GLSL: use instance.member format — instance is "{cb_prefix}_1", member is "{cb_prefix}_m{val}"
                    try w.print("{s}_1.{s}_m{d}", .{cb_prefix, cb_prefix, val});
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
pub const GlslCompileOptions = struct { version: u32 = 430, es: bool = false };

// Use shared parse cache from root (avoids circular import — cache is passed via allocator context)
pub fn spirvToGLSL(alloc: std.mem.Allocator, spirv_words: []const u32, options: GlslCompileOptions) ![]const u8 {
    var module = try parseModule(alloc, spirv_words);
    defer module.deinit(alloc);

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

    try w.print("#version {d}\n\n", .{options.version});

    // For compute shaders: emit local_size and SSBO declarations
    if (is_compute) {
        const ls = module.local_size;
        try w.print("layout(local_size_x = {d}, local_size_y = {d}, local_size_z = {d}) in;\n\n", .{ls[0], ls[1], ls[2]});
    }

    for (cbuffers.items) |cb| {
        try w.print("layout(binding = {d}, std140) uniform {s}\n{{\n", .{cb.binding, cb.name});
        try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa);
        try w.print("}} {s}_1;\n\n", .{cb.name});
    }

    // For compute shaders: emit SSBO (storage buffer) declarations
    if (is_compute) {
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                // SSBOs use StorageBuffer storage class (SPIR-V 1.3+) or Uniform + BufferBlock decoration
                const is_ssbo = sc == .StorageBuffer or (sc == .Uniform and hasDec(&decs, inst.words[2], .buffer_block));
                if (!is_ssbo) continue;
                const rid = inst.words[2];
                const binding = getDecVal(&decs, rid, .binding) orelse continue;
                const name = names.get(rid) orelse continue;
                try w.print("layout(std430, binding = {d}) buffer {s}\n{{\n", .{binding, name});
                // Emit struct members from the pointee type
                const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
                if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                    try emitStructMembers(&module, &names, ptr_inst.words[3], name, w, aa);
                }
                try w.print("}} {s};\n\n", .{name});
            }
        }
    }
    for (textures.items) |tex| {
        try w.print("layout(binding = {d}) uniform sampler2D {s};\n", .{tex.binding, tex.name});
    }
    if (textures.items.len > 0) try w.writeAll("\n");

    // Emit specialization constants as layout(constant_id = N) const declarations
    for (module.instructions) |inst| {
        if (inst.op == .SpecConstant and inst.words.len > 3) {
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
            if (spec_id) |sid| {
                // Get default value from constant words
                const default_val = if (inst.words.len > 3) inst.words[3] else 0;
                if (std.mem.eql(u8, type_str, "float")) {
                    const fv: f32 = @bitCast(default_val);
                    try w.print("layout(constant_id = {d}) const {s} {s} = {d};\n", .{sid, type_str, name, fv});
                } else {
                    try w.print("layout(constant_id = {d}) const {s} {s} = {d};\n", .{sid, type_str, name, default_val});
                }
            }
        }
    }
    try w.writeAll("\n");

    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| { if (inst.op == .Function and inst.words.len > 2) try func_ids.append(aa, inst.words[2]); }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer { var it = out_param_info.iterator(); while(it.next())|e| e.value_ptr.deinit(aa); out_param_info.deinit(); }
    detectOutParams(&module, entry_id, &out_param_info, aa);

    for (func_ids.items) |fid| { if (fid == entry_id) continue; try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info); }
    try emitFunction(&module, &names, &decs, entry_id, w, aa, true, &out_param_info);
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
fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch(op) {
        .TypeVoid,.TypeBool,.TypeInt,.TypeFloat,.TypeVector,.TypeMatrix,.TypeImage,.TypeSampler,.TypeSampledImage,.TypeArray,.TypeRuntimeArray,.TypeStruct,.TypePointer,.TypeFunction,.TypeForwardPointer,.TypeAccelerationStructureKHR,.TypeRayQueryKHR,.TypeTensorARM => if(words.len>1) words[1] else null,
        .ConstantTrue,.ConstantFalse,.Constant,.ConstantComposite,.SpecConstant,.Undef => if(words.len>2) words[2] else null,
        .Variable,.Function,.FunctionParameter => if(words.len>2) words[2] else null,
        .Load,.AccessChain,.CompositeConstruct,.CompositeExtract,.CompositeInsert,.VectorShuffle,.SampledImage,.ImageSampleImplicitLod,.ImageSampleExplicitLod,.ImageFetch,.ImageGather,.ImageQuerySizeLod,.ImageQuerySize,.ImageTexelPointer,.FunctionCall,.CopyObject,.Phi,.ConvertFToS,.ConvertSToF,.ConvertUToF,.ConvertFToU,.UConvert,.SConvert,.FConvert,.Bitcast,.SNegate,.FNegate,.IAdd,.FAdd,.ISub,.FSub,.IMul,.FMul,.UDiv,.SDiv,.FDiv,.UMod,.SRem,.FRem,.FMod,.VectorTimesScalar,.MatrixTimesScalar,.VectorTimesMatrix,.MatrixTimesVector,.MatrixTimesMatrix,.Dot,.Transpose,.OuterProduct,.Select,.LogicalOr,.LogicalAnd,.LogicalNot,.IEqual,.INotEqual,.UGreaterThan,.SGreaterThan,.UGreaterThanEqual,.SGreaterThanEqual,.ULessThan,.SLessThan,.ULessThanEqual,.SLessThanEqual,.FOrdEqual,.FOrdNotEqual,.FOrdLessThan,.FOrdGreaterThan,.FOrdLessThanEqual,.FOrdGreaterThanEqual,.ShiftRightLogical,.ShiftRightArithmetic,.ShiftLeftLogical,.BitwiseOr,.BitwiseXor,.BitwiseAnd,.Not,.BitReverse,.BitCount,.IsNan,.IsInf,.All,.Any,.DPdx,.DPdy,.Fwidth,.DPdxFine,.DPdyFine,.FwidthFine,.DPdxCoarse,.DPdyCoarse,.FwidthCoarse,.VectorExtractDynamic,.ExtInst,.OpImage,.AtomicIAdd,.AtomicISub,.AtomicExchange,.AtomicSMin,.AtomicUMin,.AtomicSMax,.AtomicUMax,.AtomicAnd,.AtomicOr,.AtomicXor,.ImageSampleDrefImplicitLod,.ImageSampleDrefExplicitLod,.ImageSampleProjImplicitLod,.ImageSampleProjExplicitLod,.ImageDrefGather,.ImageQueryLod,.ImageQueryLevels,.ImageQuerySamples,.ImageRead,.AtomicCompareExchange,.AtomicFAddEXT => if(words.len>2) words[2] else null,
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
            .Uniform => { if (hasDec(decs, rid, .buffer_block)) continue; const binding = getDecVal(decs, rid, .binding) orelse 0; cb.append(alloc, .{.name=names.get(rid) orelse "Globals", .type_id=pt, .binding=binding}) catch {}; },
            .UniformConstant => { const pei = getDef(m, pt) orelse continue; const binding = getDecVal(decs, rid, .binding) orelse 0; const name = names.get(rid) orelse "tex"; switch(pei.op){ .TypeSampledImage=>{tex.append(alloc,.{.name=name,.binding=binding}) catch {};}, .TypeImage=>{tex.append(alloc,.{.name=name,.binding=binding}) catch {};}, else=>{}} },
            else => {},
        }
    }
}

fn emitStructMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, cb_name: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const inst = getDef(m, struct_id) orelse return; if (inst.op != .TypeStruct) return;
    for (inst.words[2..], 0..) |mt_id, mi| {
        const mti = getDef(m, mt_id); if (mti) |mi2| { if (mi2.op == .TypeArray and mi2.words.len > 3) { const et = try glslType(m, mi2.words[2], names, alloc); const li = getDef(m, mi2.words[3]); const lv: u32 = if(li)|l| l.words[3] else 1; try w.print("    {s} {s}_m{d}[{d}];\n", .{et, cb_name, mi, lv}); continue; } }
        const mt = try glslType(m, mt_id, names, alloc); try w.print("    {s} {s}_m{d};\n", .{mt, cb_name, mi});
    }
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
        1 => "round", 3 => "trunc", 4, 5 => "abs", 6 => "sign", 8 => "floor", 9 => "ceil",
        10 => "fract",
        11 => "radians", 12 => "degrees", 13 => "sin", 14 => "cos", 15 => "tan",
        16 => "asin", 17 => "acos", 18 => "atan", 19 => "sinh", 20 => "cosh", 21 => "tanh",
        25 => "atan", 26 => "pow", 27 => "exp", 28 => "log", 29 => "exp2", 30 => "log2",
        31 => "sqrt", 32 => "inversesqrt", 33 => "determinant",
        37 => "min", 38 => "max", 39 => "min",
        40 => "max", 41 => "min", 42 => "max", 43 => "clamp", 44 => "clamp",
        45 => "clamp", 46 => "mix", 48 => "step", 49 => "smoothstep",
        66 => "length", 67 => "distance", 68 => "cross", 69 => "normalize",
        70 => "faceforward", 71 => "reflect", 72 => "refract",
        73 => "findLSB", 74 => "findMSB", 75 => "findMSB",
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
    if (is_frag) {
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) {
                    output_var_id = inst.words[2];
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

    // Emit output var declaration before entry function
    if (is_frag) {
        if (output_var_id) |ovid| {
            if (getDef(m, ovid)) |ov| {
                const ot = try glslType(m, ov.words[1], names, alloc);
                const on = names.get(ovid) orelse "_fragColor";
                const loc = getDecVal(decs, ovid, .location);
                if (loc) |l| {
                    try w.print("layout(location = {d}) out {s} {s};\n\n", .{ l, ot, on });
                } else {
                    try w.print("out {s} {s};\n\n", .{ ot, on });
                }
            }
        }
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
                is_out = true;
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

    // For GLSL entry points: input vars are GLSL builtins (gl_FragCoord etc.),
    // so we alias them by name instead of passing as parameters.
    if (is_frag) {
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

    var idx = func_idx + 1;
    while (idx < m.instructions.len) : (idx += 1) {
        const inst = m.instructions[idx];
        if (inst.op == .FunctionEnd) break;
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
                try w.print("    if ({s}) {{ /* TODO */ }}\n", .{cn});
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
                try w.writeAll("    // switch TODO\n");
            }
            continue;
        }

        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, output_var_id);
    }
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
) !usize {
    if (loop_idx + 1 >= m.instructions.len or m.instructions[loop_idx + 1].op != .Branch) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    const cond_lbl = m.instructions[loop_idx + 1].words[1];
    const cond_idx = label_map.get(cond_lbl) orelse {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    };
    var bc_idx: usize = cond_idx + 1;
    while (bc_idx < m.instructions.len) : (bc_idx += 1) {
        const scan = m.instructions[bc_idx];
        if (scan.op == .BranchConditional) break;
        if (scan.op == .Branch or scan.op == .FunctionEnd or scan.op == .Label) { bc_idx = m.instructions.len; break; }
    }
    if (bc_idx >= m.instructions.len) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    const bc = m.instructions[bc_idx];
    if (bc.words.len < 4) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    const body_lbl = bc.words[2];
    try w.writeAll("    while (true)\n    {\n");
    if (cond_idx + 1 < bc_idx) {
        var ci: usize = cond_idx + 1;
        while (ci < bc_idx) : (ci += 1) {
            const cinst = m.instructions[ci];
            if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
            try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid);
        }
    }
    const cond_name = names.get(bc.words[1]) orelse "true";
    try w.print("        if (!({s})) break;\n", .{cond_name});
    const body_idx = label_map.get(body_lbl) orelse m.instructions.len;
    if (body_idx < m.instructions.len) {
        var bi: usize = body_idx + 1;
        while (bi < m.instructions.len) : (bi += 1) {
            const binst = m.instructions[bi];
            if (binst.op == .FunctionEnd) break;
            if (binst.op == .Label and binst.words.len > 1) {
                const lbl = binst.words[1];
                if (lbl == cont_lbl or lbl == merge_lbl) break;
                continue;
            }
            if (binst.op == .LoopMerge or binst.op == .SelectionMerge) continue;
            if (binst.op == .Branch) {
                if (binst.words.len > 1 and (binst.words[1] == cont_lbl or binst.words[1] == merge_lbl)) continue;
                continue;
            }
            if (binst.op == .BranchConditional) {
                const ncn = names.get(binst.words[1]) orelse "c";
                const ntl = binst.words[2];
                const nfl = if (binst.words.len > 3) binst.words[3] else null;
                const nml = bc_merge.get(bi);
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    try w.print("        if ({s})\n        {{\n", .{ncn});
                    bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                    if (nhe) {
                        try w.writeAll("        } else {\n");
                        bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                    }
                    try w.writeAll("        }\n");
                    if (label_map.get(nmv)) |nmi| { bi = nmi; }
                }
                continue;
            }
            try emitInstruction(m, names, decs, binst, w, alloc, is_frag, ovid);
        }
    }
    try w.writeAll("    }\n");
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
) !usize {
    const si = lm.get(label) orelse return error.InvalidSpirv;
    var i: usize = si + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == merge_label) {
            if (is_switch) try w.print("{s}    break;\n", .{indent});
            break;
        }
        if (inst.op == .Label or inst.op == .SelectionMerge or inst.op == .LoopMerge) continue;
        if (inst.op == .Branch) {
            if (is_switch) try w.print("{s}    break;\n", .{indent});
            continue;
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
                try w.print("    {s} {s};\n", .{ tn, names.get(ri) orelse "var" });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant or sc == .Workgroup) return;
            const ri = inst.words[2];
            const tn = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s};\n", .{ tn, names.get(ri) orelse "var" });
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
        .UMod, .SRem => try emitBinOp(m, names, inst, "%", w, alloc),
        .FNegate, .SNegate => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try emitBinOp(m, names, inst, "*", w, alloc),
        .Dot => try emitCall(m, names, inst, "dot", w, alloc),
        .Transpose => try emitCall(m, names, inst, "transpose", w, alloc),
        .FOrdEqual, .IEqual => try emitBinOp(m, names, inst, "==", w, alloc),
        .FOrdNotEqual, .INotEqual => try emitBinOp(m, names, inst, "!=", w, alloc),
        .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(m, names, inst, "<", w, alloc),
        .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(m, names, inst, ">", w, alloc),
        .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(m, names, inst, "<=", w, alloc),
        .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(m, names, inst, ">=", w, alloc),
        .LogicalOr => try emitBinOp(m, names, inst, "||", w, alloc),
        .LogicalAnd => try emitBinOp(m, names, inst, "&&", w, alloc),
        .LogicalNot => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .Select => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{
                rtt, names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "c",
                names.get(inst.words[4]) orelse "t",
                names.get(inst.words[5]) orelse "f",
            });
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
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{ rtt, names.get(inst.words[2]) orelse "v", comp });
            const pt = getTypeOf(m, inst.words[3]);
            const is_vec = if (pt) |ptv| blk: {
                const pti = getDef(m, ptv);
                break :blk pti != null and pti.?.op == .TypeVector;
            } else false;
            for (inst.words[4..]) |index| {
                if (is_vec) {
                    try w.writeAll(swizzleChar(index));
                } else {
                    try w.print("[{d}]", .{index});
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
            try emitStd450(m, names, inst, inst.words[4], w, alloc);
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
        .ImageSampleProjImplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // Projected: textureProj(sampler, vec4(xy, z, w)) divides xy by w
            try w.print("    {s} {s} = textureProj({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
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
        .ImageFetch => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = texelFetch({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0" });
        },
        .Kill => try w.writeAll("    discard;\n"),
        .ControlBarrier => try w.writeAll("    barrier();\n    memoryBarrier();\n"),
        .MemoryBarrier => try w.writeAll("    memoryBarrier();\n"),

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
