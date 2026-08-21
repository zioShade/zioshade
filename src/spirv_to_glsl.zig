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
const TextureDecl = struct { name: []const u8, binding: u32, is_storage: bool = false, format_str: []const u8 = "rgba8f", dim_str: []const u8 = "2D", is_uint: bool = false, is_int: bool = false, array_size: u32 = 0, arrayed: bool = false, shadow: bool = false, is_ms: bool = false };

// ---- Helpers ----

/// Format an OpSwitch case literal with the SELECTOR's signedness.
///
/// SPIR-V stores the literal as the selector's raw bit pattern, so for a signed
/// selector 0xFFFFFFFF means -1, not 4294967295. Metal rejects the wide literal
/// outright ("case value evaluates to 4294967295, which cannot be narrowed to
/// type 'int'"), and the C-family backends silently emit a case the selector can
/// never equal -- that arm just never runs. graphicsfuzz_082 and _026 both carry
/// such a case; neither reached this code until the #early-return-arm fix stopped
/// refusing them.
/// True when an emitted case body already ends in a statement that leaves the
/// switch, so a trailing `break;` after it would be unreachable.
///
/// Deliberately a check on the EMITTED TEXT rather than on the SPIR-V. The
/// static caseTerminatorTarget helper returns null for several distinct reasons
/// (label not found, next block reached, no Branch at all), so it cannot tell a
/// case that returns from a case whose first block ends in a BranchConditional.
/// The text answers exactly the question being asked, and it is the same
/// question tools/unreachable_scan.py asks.
fn caseBodyTerminates(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '\n');
    var last: []const u8 = "";
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len != 0) last = t;
    }
    if (std.mem.eql(u8, last, "break;") or std.mem.eql(u8, last, "continue;") or
        std.mem.eql(u8, last, "discard;")) return true;
    return std.mem.startsWith(u8, last, "return") and std.mem.endsWith(u8, last, ";");
}

fn switchCaseLiteral(m: *const ParsedModule, selector_id: u32, cv: u32) i64 {
    const tid = getTypeOf(m, selector_id) orelse return cv;
    const t = getDef(m, tid) orelse return cv;
    if (t.op == .TypeInt and t.words.len > 3 and t.words[3] != 0) {
        return @as(i32, @bitCast(cv));
    }
    return cv;
}

fn getDef(m: *const ParsedModule, id: u32) ?Instruction {
    if (id >= m.id_defs.len) return null;
    const i = m.id_defs[id] orelse return null;
    if (i >= m.instructions.len) return null;
    return m.instructions[i];
}

/// The default value of an integer OpSpecConstant `id` (its literal words[3]), used to
/// resolve LocalSizeId operands to concrete workgroup dimensions. (#475)
fn glslSpecConstantDefault(m: *const ParsedModule, id: u32, fallback: u32) u32 {
    const def = getDef(m, id) orelse return fallback;
    if (def.op != .SpecConstant or def.words.len <= 3) return fallback;
    return def.words[3];
}

/// True if `rid` (a value's result id) is consumed as an operand by any real
/// (non-metadata) instruction. Its own definition contributes exactly one
/// occurrence, so >= 2 means it is referenced. Used to decide whether an UNHANDLED
/// opcode must honest-error — its result is consumed, so emitting only a
/// `// unhandled op` comment would leave an undeclared identifier (invalid GLSL) —
/// or may keep the harmless comment (dead result).
fn resultIsReferenced(m: *const ParsedModule, rid: u32) bool {
    var count: u32 = 0;
    for (m.instructions) |inst| {
        switch (inst.op) {
            .Name, .MemberName, .Decorate, .MemberDecorate => continue,
            else => {},
        }
        if (inst.words.len < 2) continue;
        for (inst.words[1..]) |wrd| {
            if (wrd == rid) {
                count += 1;
                if (count >= 2) return true;
            }
        }
    }
    return false;
}

/// Scalar base classification of a SPIR-V type id, descending through a vector to
/// its component type. Used to pick the right GLSL bit-reinterpret builtin for
/// OpBitcast (floatBitsToUint / uintBitsToFloat / floatBitsToInt / intBitsToFloat).
const ScalarBase = enum { float, sint, uint, other };
fn spvScalarBase(m: *const ParsedModule, type_id: u32) ScalarBase {
    var d = getDef(m, type_id) orelse return .other;
    if (d.op == .TypeVector and d.words.len > 2) d = getDef(m, d.words[2]) orelse return .other;
    return switch (d.op) {
        .TypeFloat => .float,
        .TypeInt => if (d.words.len > 3 and d.words[3] != 0) .sint else .uint,
        else => .other,
    };
}

/// True if `id` resolves to a STORAGE image (OpTypeImage with Sampled==2, e.g.
/// `image2D`), as opposed to a sampled texture. Used to pick imageSize vs
/// textureSize for OpImageQuerySize. Resolves the value's type and unwraps a
/// pointer (an unloaded image variable operand).
fn imageOperandIsStorage(m: *const ParsedModule, id: u32) bool {
    const def = getDef(m, id) orelse return false;
    if (def.words.len < 2) return false;
    var ti = getDef(m, def.words[1]) orelse return false;
    if (ti.op == .TypePointer and ti.words.len > 3) ti = getDef(m, ti.words[3]) orelse return false;
    if (ti.op != .TypeImage) return false;
    return ti.words.len > 7 and ti.words[7] == 2;
}

/// True if a SPIR-V type id is a vector. GLSL relational OPERATORS (`<`, `>`, `==`,
/// …) are scalar-only; a vector comparison (bvecN result) must use the builtin
/// greaterThan / lessThan / equal / notEqual family, so relationals check this.
fn isVectorType(m: *const ParsedModule, type_id: u32) bool {
    const d = getDef(m, type_id) orelse return false;
    return d.op == .TypeVector;
}

/// Emit a relational op: the scalar `op` for a bool result, or the GLSL builtin
/// `vfunc` (greaterThan/lessThan/...) for a bvecN result. Emitting `a > b` on
/// vectors is invalid GLSL (silently produced non-compiling output before).
fn emitRelOp(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, vfunc: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const a = names.get(inst.words[3]) orelse "a";
    const b = names.get(inst.words[4]) orelse "b";
    if (isVectorType(m, inst.words[1])) {
        try w.print("    {s} {s} = {s}({s}, {s});\n", .{ rtt, rn, vfunc, a, b });
    } else {
        try w.print("    {s} {s} = {s} {s} {s};\n", .{ rtt, rn, a, op, b });
    }
}
/// #170: emit a NaN-correct UNORDERED float inequality as the negation of its COMPLEMENTARY
/// ordered comparison. GLSL relational operators/functions are ORDERED (false when either
/// operand is NaN), so mapping OpFUnordLessThan and friends onto `<`/`lessThan` (as
/// spirv-cross does) is plausible-but-wrong on a NaN operand -- the unordered form must be
/// TRUE there, and `!ordered-complement` is exact by the IEEE-754 / SPIR-V definition. GLSL
/// has no scalar-operator form for vectors and no `!` on bvec, so the vector path uses
/// `not(complementFunc(a, b))`. `complement_op` is the scalar operator, `complement_vfunc`
/// the vector function of the ORDERED complement. Deliberate divergence from spirv-cross.
fn emitNegatedRelOp(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, complement_op: []const u8, complement_vfunc: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const a = names.get(inst.words[3]) orelse "a";
    const b = names.get(inst.words[4]) orelse "b";
    if (isVectorType(m, inst.words[1])) {
        try w.print("    {s} {s} = not({s}({s}, {s}));\n", .{ rtt, rn, complement_vfunc, a, b });
    } else {
        try w.print("    {s} {s} = !({s} {s} {s});\n", .{ rtt, rn, a, complement_op, b });
    }
}
/// #170 OpFUnordEqual: unordered-equal is TRUE if either operand is NaN (ordered
/// `==`/`equal` is false there = plausible-but-wrong). GLSL has no `isunordered`
/// and `||` does not operate on bvec, so the scalar emits isnan(a)||isnan(b)||(a==b)
/// and the vector builds the bvec per-component (the only componentwise form that
/// compiles). (spirv-cross GLSL emits `!(a != b)`, which is NaN-wrong; zioshade
/// diverges to be correct.) OpFUnordNotEqual is already exact on `!=`/`notEqual`
/// (GLSL != is unordered = true on NaN, matching the opcode).
fn emitUnordEqual(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const a = names.get(inst.words[3]) orelse "a";
    const b = names.get(inst.words[4]) orelse "b";
    if (isVectorType(m, inst.words[1])) {
        const swz = [_][]const u8{ "x", "y", "z", "w" };
        const width: usize = blk: {
            const d = getDef(m, inst.words[1]) orelse break :blk 0;
            if (d.op == .TypeVector and d.words.len > 3) break :blk d.words[3];
            break :blk 0;
        };
        if (width < 2 or width > 4) return error.UnsupportedVectorWidth;
        try w.print("    {s} {s} = {s}(", .{ rtt, rn, rtt });
        var i: usize = 0;
        while (i < width) : (i += 1) {
            if (i > 0) try w.writeAll(", ");
            try w.print("isnan({s}).{s} || isnan({s}).{s} || ({s}.{s} == {s}.{s})", .{
                a, swz[i], b, swz[i], a, swz[i], b, swz[i],
            });
        }
        try w.writeAll(");\n");
    } else {
        try w.print("    {s} {s} = isnan({s}) || isnan({s}) || ({s} == {s});\n", .{ rtt, rn, a, b, a, b });
    }
}

/// #170 OpFOrdNotEqual: ordered not-equal is FALSE on a NaN operand, but GLSL `!=`/
/// `notEqual` is unordered (true on NaN -- which is why it is the correct lowering for
/// OpFUnordNotEqual), so bare `!=` is plausible-but-wrong for the ORDERED form. Lower
/// to `!isnan(a) && !isnan(b) && (a != b)` (scalar) and a per-component bvecN for
/// vectors (GLSL has no componentwise && on bvec). The mirror of emitUnordEqual.
fn emitOrdNotEqual(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const a = names.get(inst.words[3]) orelse "a";
    const b = names.get(inst.words[4]) orelse "b";
    if (isVectorType(m, inst.words[1])) {
        const swz = [_][]const u8{ "x", "y", "z", "w" };
        const width: usize = blk: {
            const d = getDef(m, inst.words[1]) orelse break :blk 0;
            if (d.op == .TypeVector and d.words.len > 3) break :blk d.words[3];
            break :blk 0;
        };
        if (width < 2 or width > 4) return error.UnsupportedVectorWidth;
        try w.print("    {s} {s} = {s}(", .{ rtt, rn, rtt });
        var i: usize = 0;
        while (i < width) : (i += 1) {
            if (i > 0) try w.writeAll(", ");
            try w.print("!isnan({s}).{s} && !isnan({s}).{s} && ({s}.{s} != {s}.{s})", .{
                a, swz[i], b, swz[i], a, swz[i], b, swz[i],
            });
        }
        try w.writeAll(");\n");
    } else {
        try w.print("    {s} {s} = !isnan({s}) && !isnan({s}) && ({s} != {s});\n", .{ rtt, rn, a, b, a, b });
    }
}

/// Element type reached by descending one composite level: the element type of an
/// array (fixed or runtime), the column type of a matrix, or the component type of
/// a vector. Used per access-chain index for the runtime-index descent (#419).
fn elemType(m: *const ParsedModule, tid: u32) ?u32 {
    const t = getDef(m, tid) orelse return null;
    return switch (t.op) {
        .TypeArray, .TypeRuntimeArray, .TypeMatrix, .TypeVector => t.words[2],
        else => null,
    };
}
fn getTypeOf(m: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(m, id) orelse return null;
    return switch (inst.op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix, .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray, .TypeStruct, .TypePointer, .TypeFunction => null,
        else => if (inst.words.len > 1) inst.words[1] else null,
    };
}
fn swizzleChar(i: u32) []const u8 {
    return switch (i) {
        0 => ".x",
        1 => ".y",
        2 => ".z",
        3 => ".w",
        else => ".x",
    };
}
fn parseLitStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, words.len * 4);
    for (words) |word| {
        const bytes: [4]u8 = @bitCast(word);
        for (bytes) |c| {
            if (c == 0) break;
            buf.appendAssumeCapacity(c);
        }
    }
    return buf.toOwnedSlice(alloc);
}
/// Splice `#extension <name> : require` directives for the extension-gated gl_*
/// builtins the emitted GLSL actually references. A builtin such as
/// gl_FragStencilRefARB or gl_DrawID is only in scope once its extension is
/// requested, so without this glslang rejects the (otherwise correct) output with
/// "undeclared identifier" / "required extension not requested". Keyed on the
/// emitted gl_* token — the ground truth, and the EXT/NV suffix cleanly separates
/// the KHR and NV barycentric variants (whose SPIR-V capability/BuiltIn coincide).
/// The directives must precede the first use, so they are inserted right after the
/// `#version` line once the body is known.
/// Rewrite the `#version` line upward when the emitted GLSL references features
/// that need a higher core version than `options.version` (the default 430):
///   * interface blocks (in/out blocks with location qualifiers) → 450, raised
///     during emission via `needs_version`
///   * gl_HelperInvocation / gl_CullDistance → 460 core
///   * textureSamples() (multisample image query) → 450 core
/// This is the version counterpart of `spliceRequiredExtensions` (which splices
/// `#extension` pragmas). Both run as a post-pass once the body is known. The
/// `#version` line is always first, so the rewrite replaces line 1 only.
fn spliceRequiredVersion(output: *std.ArrayList(u8), alloc: std.mem.Allocator, base_version: u32, needs_version: u32) !void {
    var required: u32 = needs_version;
    if (std.mem.indexOf(u8, output.items, "gl_HelperInvocation") != null) required = @max(required, 460);
    if (std.mem.indexOf(u8, output.items, "gl_CullDistance") != null) required = @max(required, 460);
    if (std.mem.indexOf(u8, output.items, "textureSamples(") != null) required = @max(required, 450);
    if (required <= base_version) return;
    const nl = std.mem.indexOfScalar(u8, output.items, '\n') orelse return;
    const new_line = std.fmt.allocPrint(alloc, "#version {d}", .{required}) catch return;
    defer alloc.free(new_line);
    try output.replaceRange(alloc, 0, nl, new_line);
}

fn spliceRequiredExtensions(output: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    // Only builtins whose extension request ALONE makes the output valid are
    // listed. gl_DrawID (a vertex-only builtin misused in fragment) and the
    // barycentric inputs (which also need per-vertex `pervertexEXT` arrays) need
    // more than a pragma, so they are left to refuse/deeper work, not half-fixed.
    const map = [_]struct { token: []const u8, ext: []const u8 }{
        .{ .token = "gl_FragStencilRefARB", .ext = "GL_ARB_shader_stencil_export" },
        // #170: ARB-spelling draw_parameters builtins need GL_ARB_shader_draw_parameters.
        .{ .token = "gl_BaseVertexARB", .ext = "GL_ARB_shader_draw_parameters" },
        .{ .token = "gl_BaseInstanceARB", .ext = "GL_ARB_shader_draw_parameters" },
        .{ .token = "gl_DrawIDARB", .ext = "GL_ARB_shader_draw_parameters" },
        // #474: coarse/fine derivatives are 4.5 core but need this ARB extension on
        // the older #version zioshade targets by default. All six spellings gate on
        // the same extension; requiring it is harmless (satisfied) when already core.
        .{ .token = "dFdxCoarse", .ext = "GL_ARB_derivative_control" },
        .{ .token = "dFdxFine", .ext = "GL_ARB_derivative_control" },
        .{ .token = "dFdyCoarse", .ext = "GL_ARB_derivative_control" },
        .{ .token = "dFdyFine", .ext = "GL_ARB_derivative_control" },
        .{ .token = "fwidthCoarse", .ext = "GL_ARB_derivative_control" },
        .{ .token = "fwidthFine", .ext = "GL_ARB_derivative_control" },
        // #subgroup-operand: subgroup builtins/arithmetic need their KHR pragmas.
        // basic gates the gl_SubgroupInvocationID builtin; arithmetic gates the
        // subgroup{Add,Mul,Min,Max,And,Or,Xor} + Inclusive/Exclusive scans;
        // clustered gates subgroupClustered*. (detected via substring tokens.)
        .{ .token = "gl_SubgroupInvocationID", .ext = "GL_KHR_shader_subgroup_basic" },
        .{ .token = "subgroupAdd(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupMul(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupMin(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupMax(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupAnd(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupOr(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupXor(", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupInclusive", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupExclusive", .ext = "GL_KHR_shader_subgroup_arithmetic" },
        .{ .token = "subgroupClustered", .ext = "GL_KHR_shader_subgroup_clustered" },
    };
    var block = std.ArrayList(u8).initCapacity(alloc, 128) catch return;
    defer block.deinit(alloc);
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (map) |m| {
        if (std.mem.indexOf(u8, output.items, m.token) == null) continue;
        if (seen.contains(m.ext)) continue;
        seen.put(m.ext, {}) catch {};
        block.print(alloc, "#extension {s} : require\n", .{m.ext}) catch {};
    }
    // textureLod on a shadow sampler (sampler*Shadow) needs GL_EXT_texture_shadow_lod
    // (core GLSL has no Lod on comparison samplers). Gate on the co-occurrence of a
    // shadow-sampler type and a textureLod call. (#GLSL-corpus)
    if (std.mem.indexOf(u8, output.items, "textureLod(") != null and std.mem.indexOf(u8, output.items, "Shadow") != null) {
        if (!seen.contains("GL_EXT_texture_shadow_lod")) {
            seen.put("GL_EXT_texture_shadow_lod", {}) catch {};
            block.print(alloc, "#extension GL_EXT_texture_shadow_lod : require\n", .{}) catch {};
        }
    }
    // OpSelect over INTEGER operands lowers to mix(); core GLSL mix is genType=float
    // only, so integer mix needs GL_EXT_shader_integer_mix. (Flag set in the Select
    // handler when the result type is int/uint scalar/vector.)
    if (g_int_mix_needed and !seen.contains("GL_EXT_shader_integer_mix")) {
        seen.put("GL_EXT_shader_integer_mix", {}) catch {};
        block.print(alloc, "#extension GL_EXT_shader_integer_mix : require\n", .{}) catch {};
    }
    if (block.items.len == 0) return;
    const nl = std.mem.indexOfScalar(u8, output.items, '\n') orelse return;
    try output.insertSlice(alloc, nl + 1, block.items);
}

fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, name.len);
    // No-op after a successful toOwnedSlice (which empties the list); reclaims
    // the backing allocation on the append / toOwnedSlice error paths.
    defer buf.deinit(alloc);
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => buf.appendAssumeCapacity(c),
            else => buf.appendAssumeCapacity('_'),
        }
    }
    // A sanitized OpName can collide with a GLSL reserved word -- e.g. a shader
    // naming a function parameter `input` -- which glslang rejects ("Reserved
    // word"). Append `_` so the emitted identifier is always legal. The rename
    // is consistent (every use of the id resolves through the same names map)
    // and `X_` is itself a legal, non-reserved identifier.
    // Scope: this covers id names only -- struct member names take a separate
    // path (commonGetMemberName) and are not mangled, so a reserved-word member
    // still yields loud-invalid GLSL. Two ids can still collide (e.g. `input`
    // -> `input_` next to an existing `input_`); that sanitize-to-same-string
    // collision class is pre-existing (any `a-b`/`a_b` pair already hit it) and
    // is tracked separately for a value-dedup fix needing render-diff verify.
    if (isGlslReservedWord(buf.items)) try buf.append(alloc, '_');
    return buf.toOwnedSlice(alloc);
}

fn isGlslReservedWord(s: []const u8) bool {
    const reserved = [_][]const u8{
        // statement / control-flow keywords
        "if",        "else",      "for",      "while",     "do",            "switch",
        "case",      "default",   "break",    "continue",  "return",        "discard",
        // scalar / vector / matrix type keywords
        "void",      "bool",      "int",      "uint",      "float",         "double",
        "vec2",      "vec3",      "vec4",     "ivec2",     "ivec3",         "ivec4",
        "uvec2",     "uvec3",     "uvec4",    "bvec2",     "bvec3",         "bvec4",
        "dvec2",     "dvec3",     "dvec4",    "mat2",      "mat3",          "mat4",
        // qualifier / storage-class / memory keywords
        "const",     "in",        "out",      "inout",     "uniform",       "varying",
        "attribute", "centroid",  "flat",     "smooth",    "noperspective", "patch",
        "sample",    "invariant", "precise",  "layout",    "buffer",        "shared",
        "coherent",  "restrict",  "readonly", "writeonly", "volatile",
        // literals, struct, and reserved words (input/output trip glslang)
             "true",
        "false",     "struct",    "input",    "output",    "atomic_uint",   "subroutine",
    };
    for (reserved) |r| if (std.mem.eql(u8, r, s)) return true;
    return false;
}
fn isUniformVar(m: *const ParsedModule, id: u32) bool {
    const inst = getDef(m, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        return sc == .Uniform;
    }
    return false;
}

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
    // writable `buffer` block (the SSBO emission loop now runs in every stage, not just
    // compute). There it keeps its original member names + `{instance}.{member}` access, so
    // it must NOT take the cbuffer `{name}_1.{name}_m{idx}` form. (#296)
    if (structHasBufferBlock(m, pt)) return false;
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
/// type carries `BufferBlock` (glslangValidator's SSBO encoding). zioshade's own frontend uses
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
/// gl_PerVertex builtin-block base suppression (isBuiltinBlockVar). Applies in every stage,
/// in lockstep with the SSBO emission loop and isUniformBlockVar's BufferBlock exclusion.
fn isAnonymousSSBOVar(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32) bool {
    const def = getDef(m, id) orelse return false;
    if (def.op != .Variable or def.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(def.words[3]);
    if (sc != .StorageBuffer and !isOldStyleSSBOVar(m, id)) return false;
    const nm = names.get(id) orelse return true; // absent OpName ⇒ anonymous
    return nm.len == 0;
}

fn resolvePointee(m: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(m, id) orelse return null;
    switch (inst.op) {
        // OpFunctionParameter shares OpVariable's word layout (words[1] = pointer
        // result type). A pointer param (`inout Particle p`) whose pointee is a struct
        // was otherwise unresolved (null), so its access chains emitted a numeric index
        // (`v[1]`) instead of the member name (`.vel`) — invalid GLSL.
        .Variable, .FunctionParameter => {
            const pt = getDef(m, inst.words[1]) orelse return null;
            if (pt.op == .TypePointer and pt.words.len > 3) return pt.words[3];
            return null;
        },
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
                                    if (v + 2 < tinst.words.len) {
                                        cur = tinst.words[v + 2];
                                    } else cur = null;
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

/// Whether block `target` is reachable from block `cur` by following terminators,
/// WITHOUT entering `stop` (the selection merge). Used to attribute an OpPhi
/// predecessor to the true vs false side of a selection: with NESTED control flow
/// the phi's real predecessor is an inner merge block, not the immediate true/false
/// label, so matching the predecessor by label equality picks the wrong incoming
/// value (swapping the branches). Reachability from the true label — stopping at
/// the merge so the two branch regions stay disjoint — attributes it correctly.
fn labelReaches(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), cur: u32, target: u32, stop: u32, seen: *std.AutoHashMap(u32, void)) bool {
    if (cur == stop) return false;
    if (cur == target) return true;
    if (seen.contains(cur)) return false;
    seen.put(cur, {}) catch return false;
    const bi = label_map.get(cur) orelse return false;
    var j = bi + 1;
    while (j < m.instructions.len) : (j += 1) {
        const inst = m.instructions[j];
        switch (inst.op) {
            .Branch => return if (inst.words.len >= 2) labelReaches(m, label_map, inst.words[1], target, stop, seen) else false,
            .BranchConditional => {
                if (inst.words.len < 4) return false;
                if (labelReaches(m, label_map, inst.words[2], target, stop, seen)) return true;
                return labelReaches(m, label_map, inst.words[3], target, stop, seen);
            },
            .Switch => {
                if (inst.words.len >= 3 and labelReaches(m, label_map, inst.words[2], target, stop, seen)) return true;
                var k: usize = 3;
                while (k + 1 < inst.words.len) : (k += 2) {
                    if (labelReaches(m, label_map, inst.words[k + 1], target, stop, seen)) return true;
                }
                return false;
            },
            .Return, .ReturnValue, .Kill, .Unreachable, .Label => return false,
            else => {},
        }
    }
    return false;
}

/// True if the phi predecessor `pred1` lies in the TRUE region of a selection
/// (reachable from the true label `tl`, stopping at the merge `mval`).
fn phiPred1InTrueRegion(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), tl: u32, mval: u32, pred1: u32, alloc: std.mem.Allocator) bool {
    var seen = std.AutoHashMap(u32, void).init(alloc);
    defer seen.deinit();
    return labelReaches(m, label_map, tl, pred1, mval, &seen);
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
fn isBuiltinBlockType(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), struct_id: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 5 and inst.words[1] == struct_id) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .built_in) return true;
        }
    }
    // Name fallback: the gl_PerVertex builtin block, whose members the frontend
    // does not decorate BuiltIn. Detected by the reserved struct name. Without
    // this the block is declared as a tagged `out` varying and member access keeps
    // the instance prefix, which glslang rejects (it must be the canonical
    // `out gl_PerVertex { … };` redeclaration with bare gl_* member access).
    if (names.get(struct_id)) |sname| {
        if (std.mem.eql(u8, sname, "gl_PerVertex")) return true;
    }
    return false;
}

/// True when `var_id` is a variable whose pointee type is a built-in interface
/// block (gl_PerVertex). Such variables must NOT be declared as `out`/`in`
/// varyings — their members (gl_Position, …) are predefined in GLSL — and member
/// access through them must lower to the bare gl_* name (no block instance prefix).
fn isBuiltinBlockVar(m: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), var_id: u32) bool {
    const pointee = resolvePointee(m, var_id) orelse return false;
    return isBuiltinBlockType(m, names, pointee);
}

/// Map a gl_PerVertex-style BuiltIn member to its predefined GLSL name. Returns
/// null for builtins zioshade doesn't lower to a bare gl_* (caller falls back to the
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
    const base_is_builtin_block = isBuiltinBlockVar(m, names, base_id);
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
                const is_struct_member = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeStruct;
                } else false;
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    writer.writeAll(swizzleChar(val));
                } else if (cb_level and base_is_cb) {
                    writer.print("{s}_m{d}", .{ cb_prefix, val });
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
                        if (base_is_builtin_block) {
                            writer.writeAll(mname);
                        } else if (anon_level) {
                            writer.writeAll(mname);
                            anon_level = false;
                        } else writer.print(".{s}", .{mname});
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
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeRuntimeArray or tinst.op == .TypeMatrix) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                writer.print("[{s}]", .{names.get(index_id) orelse "i"});
                // Runtime index: descend into the element type (see #419 above).
                if (cur_type) |tid2| cur_type = elemType(m, tid2);
            }
        } else {
            writer.print("[{s}]", .{names.get(index_id) orelse "i"});
            if (cur_type) |tid2| cur_type = elemType(m, tid2);
        }
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
                const is_struct_member = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeStruct;
                } else false;
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    try buf.appendSlice(alloc, swizzleChar(val));
                } else if (cb_level2 and base_is_cb) {
                    try buf.print(alloc, "{s}_m{d}", .{ cb_prefix, val });
                    cb_level2 = false;
                } else if (is_struct_member) {
                    if (structMemberBuiltin(m, cur_type.?, val)) |bi| {
                        var mname_buf: [32]u8 = undefined;
                        const gn = builtinBlockMemberName(bi) orelse getMemberName(m, cur_type.?, val, &mname_buf);
                        if (base_is_builtin_block) try buf.appendSlice(alloc, gn) else try buf.print(alloc, ".{s}", .{gn});
                    } else {
                        var mname_buf: [32]u8 = undefined;
                        const mname = getMemberName(m, cur_type.?, val, &mname_buf);
                        if (anon_level2) {
                            try buf.appendSlice(alloc, mname);
                            anon_level2 = false;
                        } else try buf.print(alloc, ".{s}", .{mname});
                    }
                } else {
                    try buf.print(alloc, "[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeRuntimeArray or tinst.op == .TypeMatrix) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn writeResolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, w: anytype) !void {
    const inst = getDef(m, ptr_id) orelse {
        try w.writeAll(names.get(ptr_id) orelse "var");
        return;
    };
    if (inst.op == .AccessChain) {
        try writeAccessExpr(m, names, inst.words[3], inst.words[4..], w);
        return;
    }
    try w.writeAll(names.get(ptr_id) orelse "var");
}

fn writeAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) {
        try w.writeAll(base_name);
        return;
    }
    // Bare-array Uniform vars are not blocks — index directly (`w[2]`), #289.
    const base_is_cb = isUniformBlockVar(m, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    const base_is_builtin_block = isBuiltinBlockVar(m, names, base_id);
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
                const is_struct_member = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeStruct;
                } else false;
                const is_vector = if (cur_type) |tid| blk: {
                    const ti = getDef(m, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else if (cb_level and base_is_cb) {
                    // GLSL: use instance.member format — instance is "{cb_prefix}_1", member is "{cb_prefix}_m{val}"
                    try w.print("{s}_1.{s}_m{d}", .{ cb_prefix, cb_prefix, val });
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
                        if (base_is_builtin_block) {
                            // gl_PerVertex member with no BuiltIn decoration (frontend
                            // gap): emit the bare member name (gl_Position), no dot --
                            // the block instance base was suppressed above.
                            try w.writeAll(mname);
                        } else if (anon_level) {
                            try w.writeAll(mname);
                            anon_level = false;
                        } else try w.print(".{s}", .{mname});
                    }
                } else {
                    try w.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur_type = tinst.words[2];
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            cur_type = tinst.words[val + 2];
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeRuntimeArray or tinst.op == .TypeMatrix) {
                            cur_type = tinst.words[2];
                        } else {
                            cur_type = null;
                        }
                    }
                }
            } else {
                try w.print("[{s}]", .{names.get(index_id) orelse "i"});
                // Runtime (non-constant) index: descend into the element type, so a
                // following struct-member index resolves to a member name instead of
                // being misread as another array index and printed as [n] (#419).
                if (cur_type) |tid2| cur_type = elemType(m, tid2);
            }
        } else {
            try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            if (cur_type) |tid2| cur_type = elemType(m, tid2);
        }
    }
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
    const inst = getDef(m, type_id) orelse return error.CrossCompileUnsupported;
    return switch (inst.op) {
        .TypeVoid => "void",
        .TypeBool => "bool",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeFloat => if (inst.words.len > 2 and inst.words[2] == 16) "float16_t" else "float",
        .TypeVector => {
            const s = try glslType(m, inst.words[2], names, alloc);
            const c = inst.words[3];
            if (std.mem.eql(u8, s, "float")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "float", "vec2", "vec3", "vec4" })[c];
            } else if (std.mem.eql(u8, s, "float16_t")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "float16_t", "f16vec2", "f16vec3", "f16vec4" })[c];
            } else if (std.mem.eql(u8, s, "int")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "int", "ivec2", "ivec3", "ivec4" })[c];
            } else if (std.mem.eql(u8, s, "uint")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "uint", "uvec2", "uvec3", "uvec4" })[c];
            } else if (std.mem.eql(u8, s, "bool")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "bool", "bvec2", "bvec3", "bvec4" })[c];
            }
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ s, c });
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const ct = getDef(m, inst.words[2]);
            const rows: u32 = if (ct) |c| c.words[3] else cols;
            if (cols == rows and cols >= 2 and cols <= 4) return ([_][]const u8{ "", "", "mat2", "mat3", "mat4" })[cols];
            return std.fmt.allocPrint(alloc, "mat{d}x{d}", .{ cols, rows });
        },
        .TypeArray, .TypeRuntimeArray => try glslType(m, inst.words[2], names, alloc),
        .TypePointer => if (inst.words.len > 3) try glslType(m, inst.words[3], names, alloc) else return error.CrossCompileUnsupported,
        .TypeStruct => names.get(type_id) orelse "Struct",
        else => return error.CrossCompileUnsupported,
    };
}

/// Full GLSL type spelling for a (non-pointer) type id, INCLUDING array dimensions
/// ('vec4[2]', 'float[2][3]'). glslType alone returns the ELEMENT type for an array,
/// so a function that returns an array ('vec4[2] func()') was declared 'vec4 func()'
/// and the body's array return was a type mismatch. Used for return types; glslType
/// stays the default elsewhere. Spec-constant-length aware.
fn glslTypeWithDims(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const elem = try glslType(m, type_id, names, alloc);
    var dims = std.ArrayList(u8).initCapacity(alloc, 16) catch return error.OutOfMemory;
    var cur = getDef(m, type_id);
    while (cur) |c| {
        if (c.op != .TypeArray or c.words.len < 4) break;
        const len_def = getDef(m, c.words[3]);
        const n: u32 = if (len_def) |ld| (if ((ld.op == .Constant or ld.op == .SpecConstant) and ld.words.len > 3) ld.words[3] else 0) else 0;
        try dims.print(alloc, "[{d}]", .{n});
        cur = getDef(m, c.words[2]);
    }
    if (dims.items.len == 0) {
        dims.deinit(alloc);
        return elem;
    }
    const result = try std.fmt.allocPrint(alloc, "{s}{s}", .{ elem, dims.items });
    dims.deinit(alloc);
    return result;
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

/// #413: a loop-phi UPDATE value that is defined INSIDE the loop (body,
/// condition block, or a Pattern-B header replayed inside the loop) is
/// declared textually AFTER the top-of-loop carry copy (#237) that reads it,
/// and inside the while-body scope. Its declaration must be hoisted above the
/// loop header (declare-then-assign split); the defining instruction then
/// emits a plain assignment. See spirv_cross_common.zig.
/// LoopMerge instruction index -> update temps whose declaration is emitted
/// just above that loop.
threadlocal var g_loop_hoists: ?*const std.AutoHashMap(usize, std.ArrayList(common.HoistedPhiSrc)) = null;
/// All hoisted ids (any loop): their defining instruction emits `name = expr;`
/// instead of `type name = expr;`.
threadlocal var g_hoisted_ids: ?*const std.AutoHashMap(u32, void) = null;
/// Re-entrancy guard for the strip-the-type re-render in emitInstruction.
threadlocal var g_hoist_stripping: bool = false;

// Set when an OpSelect lowers to integer mix() (bvec selector over int/uint
// operands) — needs GL_EXT_shader_integer_mix (core GLSL mix is genType=float
// only). Read by spliceRequiredExtensions.
threadlocal var g_int_mix_needed: bool = false;
// #loop-break-on-selection-merge: the enclosing loop's merge AND continue labels,
// so an OpBranch to the merge from a side-effecting break block can emit `break;`
// and an OpBranch to the continue (e.g. a switch case that continues the outer
// loop) can emit `continue;`. Mirrors MSL's g_loop_merge_ctx. Set per-loop by
// emitWhileLoop, saved/restored for nesting.
// #loop-merge-phi: merge_phis carries this loop's divergent merge-block phis so
// the same break site assigns each carrier its incoming for THAT predecessor
// before the `break;` (a break without the copy leaves the carrier holding the
// normal-exit fallback value, silently dropping the break path's distinct value).
// #loop-merge-phi-do-while: pattern_c marks a pattern-C do-while (while(true)
// with the latch/copies/bottom test at the END of the body). A GLSL `continue`
// there jumps to the top and skips them, so cont-branch sites must fall through
// linearly instead; every body OpBranch-to-cont in an ADMITTED pattern-C loop is
// the adjacent final fall-through (mid-body continues are refused at admission
// by doWhileBodyHasContinueGLSL).
const LoopMergeCtx = struct { merge_label: u32, continue_label: u32, merge_phis: []const Instruction = &.{}, pattern_c: bool = false };
threadlocal var g_loop_merge_ctx: ?LoopMergeCtx = null;

// #ladder-phi-hoist: merge phis whose incoming is ITSELF a phi defined inside
// one of the selection's arms (an else-if chain). The arm's nested emission
// declares that inner phi inside the arm's nested braces, but this level's arm
// copy prints AFTER those braces close = out of scope (graphicsfuzz_080's
// 9-level ladder). The outer handler pre-declares the inner phi at the ARM TOP
// and records its result id here; the nested handler's decl loop consumes the
// marker and skips its own (now-shadowing) declaration, keeping assignments.
const PhiDeclGLSL = struct { result_id: u32, type_id: u32, vals: [2]u32, preds: [2]u32 };
// threadlocal, like every sibling global: concurrent spirvToGLSL calls each
// own their map (a shared one races the per-compile reset across threads --
// review finding, PR #655).
threadlocal var g_predeclared_arm_phis: std.AutoHashMap(u32, void) = undefined;
threadlocal var g_predeclared_arm_phis_init = false;

// #switch-arm-break: the innermost enclosing SWITCH's merge + its merge phis, so
// an if-arm (or any nested block) whose OpBranch targets the SWITCH's merge can
// emit the per-edge phi copy + `break;` (a break out of the switch from inside a
// selection — previously the walker ended at the OpBranch emitting NOTHING: the
// early-exit never fired and the merge phi kept its stale value, silent-wrong;
// graphicsfuzz_021). Mirrors MSL's g_switch_ctx.
const SwitchCtxGLSL = struct { merge_label: u32, phis: []const Instruction };
threadlocal var g_switch_ctx_glsl: ?SwitchCtxGLSL = null;

// #loop-break-out-of-switch: a branch from INSIDE a loop body to the enclosing
// switch's merge block (a multi-level break, out of BOTH the loop and the switch)
// cannot lower to a bare `break;` in C -- the break only exits the LOOP, and the
// code after the loop in the case then runs and clobbers the switch-merge phi
// (silent-wrong: the early-exit path rendered the fall-through value). spirv-val
// rejects the shape (a loop-construct block may only branch within the construct,
// to the loop's own merge, or to the continue target), so a VALID module never
// carries it -- but zioshade ingests unvalidated SPIR-V, and whatever it accepts
// must be honest. The lowering is the classic flag idiom: each loop walker that
// finds such a branch declares `bool _swbrk_N = false;` above the loop, every
// break-to-switch-merge site inside the region sets it before its `break;`, and
// right after the loop `if (_swbrk_N) break;` exits the switch (or, for a loop
// nested in another loop, sets the parent flag and breaks ONE level -- each
// walker's post-loop guard carries it the rest of the way out). Null while not
// inside an armed loop. Port of MSL's g_swbrk_flag.
threadlocal var g_swbrk_flag_glsl: ?[]const u8 = null;
const max_emit_while_depth: u32 = 256;
threadlocal var g_ewl_depth: u32 = 0;

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
        // #413: an inner loop's phi variable can be an OUTER loop's carry
        // source; its declaration was hoisted above the outer loop, so only
        // the init assignment is emitted here.
        const hoisted = if (g_hoisted_ids) |h| h.contains(pi.result_id) else false;
        if (hoisted) {
            try w.print("{s}{s} = {s};\n", .{ indent, vname, init_name });
        } else {
            try w.print("{s}{s} {s} = {s};\n", .{ indent, tyname, vname, init_name });
        }
    }
    return true;
}

fn isDeferredHdrGLSL(idx: usize) bool {
    const dh = g_deferred_hdr orelse return false;
    return dh.contains(idx);
}

/// True if `label` heads a loop, i.e. its block carries an OpLoopMerge.
///
/// The block is scanned to its terminator rather than only past its leading
/// OpPhis. A Pattern-B header computes the loop condition (and whatever else it
/// needs) BETWEEN the phis and the OpLoopMerge, so for a plain
/// `for (int i = 0; i < 3; i++)` the OpSLessThan sits in the way. A phi-only
/// scan concludes "not a loop header" and whoever asked treats the branch into
/// the loop as the end of its region -- which is how a loop nested in a
/// selection arm came to be dropped whole (#loop-in-selection-arm).
///
/// An OpSelectionMerge terminates the scan: a selection header is not a loop
/// header, and its own merge instruction must not be mistaken for one.
fn isLoopHeaderGLSL(m: *const ParsedModule, lm: *const std.AutoHashMap(u32, usize), label: u32) bool {
    const hi = lm.get(label) orelse return false;
    var i: usize = hi + 1;
    while (i < m.instructions.len) : (i += 1) {
        switch (m.instructions[i].op) {
            .LoopMerge => return true,
            .Label,
            .SelectionMerge,
            .Branch,
            .BranchConditional,
            .Switch,
            .Return,
            .ReturnValue,
            .Kill,
            .Unreachable,
            .FunctionEnd,
            => return false,
            else => {},
        }
    }
    return false;
}

/// True if `rid` is a loop back-edge carrier hoisted above its loop by the #413
/// pre-scan (recorded in g_hoisted_ids). Such a phi is the loop-header phi's
/// update; the loop-top carry copy reads its carrier name, so a body selection
/// that materializes it MUST write the carrier name (not a disconnected `_phi`
/// temp), exactly like a `carried_phis` phi. See emitWhileLoop's body
/// BranchConditional handler (#phi-carrier).
fn phiIsHoistedLoopCarrierGLSL(rid: u32) bool {
    return if (g_hoisted_ids) |h| h.contains(rid) else false;
}

fn tryResolveTypeName(m: *const ParsedModule, type_id: u32) []const u8 {
    const inst = getDef(m, type_id) orelse return "float";
    return switch (inst.op) {
        .TypeFloat => "float",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeBool => "bool",
        else => "float",
    };
}

/// True if `s` is a bare integer (optional leading '-', then only digits) — i.e. a
/// GLSL *integer* literal, not a float. `inf`/`nan` and anything with `.`/`e`/`E`
/// are not.
fn isBareIntegerString(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = if (s[0] == '-') 1 else 0;
    if (i >= s.len) return false;
    while (i < s.len) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) return false;
    }
    return true;
}

fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    // #476: width-aware. A 64-bit constant occupies TWO words but only the first is read
    // (silent truncation/garbage); a 16-bit float literal is stored in the low bits of the
    // word but @bitCast-as-f32 yields a garbage denormal. Honest-error both — the call
    // site skips the declaration, so a USED constant fails loudly (undeclared) downstream
    // rather than compiling to a wrong value. Mirrors WGSL's width gates. A signed int16's
    // value is zero-filled in the high bits; sign-extend the low 16 bits (int16 IS a
    // supported — widened-to-int — type, so this is a correct fix, not an error).
    if (type_inst.op == .TypeFloat and type_inst.words.len > 2) {
        const w = type_inst.words[2];
        if (w == 64) return error.UnsupportedConstantWidth;
        // f16 literal: stored in the low 16 bits of the word; decode to f32 and format
        // (f16 max ~65504 < 1e6, so the whole-valued ".0" form always suffices). (#476)
        if (w == 16 and literal_words.len > 0) {
            const h: f16 = @bitCast(@as(u16, @truncate(literal_words[0])));
            const val: f32 = @floatCast(h);
            if (val == @floor(val)) {
                const ival: i32 = @intFromFloat(val);
                return std.fmt.allocPrint(alloc, "{d}.0", .{ival});
            }
            return std.fmt.allocPrint(alloc, "{d}", .{val});
        }
    } else if (type_inst.op == .TypeInt and type_inst.words.len > 2) {
        const w = type_inst.words[2];
        if (w == 64) return error.UnsupportedConstantWidth;
        if (w == 16 and type_inst.words.len > 3 and type_inst.words[3] != 0 and literal_words.len > 0) {
            const v: i16 = @bitCast(@as(u16, @truncate(literal_words[0])));
            return std.fmt.allocPrint(alloc, "{d}", .{v});
        }
    }
    if (type_inst.op == .TypeFloat and literal_words.len > 0) {
        const val: f32 = @bitCast(literal_words[0]);
        if (val == @floor(val) and @abs(val) < 1e6) {
            const ival: i32 = @intFromFloat(val);
            return std.fmt.allocPrint(alloc, "{d}.0", .{ival});
        }
        // `{d}` on a whole-valued float >= 1e6 prints bare digits (1e10 ->
        // "10000000000") with no decimal or exponent, which glslang lexes as an int
        // literal and rejects ("numeric literal too big"). Append ".0" when the
        // formatted value is a bare integer so it stays a valid float literal.
        const s = try std.fmt.allocPrint(alloc, "{d}", .{val});
        if (isBareIntegerString(s)) {
            defer alloc.free(s);
            return std.fmt.allocPrint(alloc, "{s}.0", .{s});
        }
        return s;
    }
    if (type_inst.op == .TypeInt and literal_words.len > 0) {
        const signed = type_inst.words.len > 3 and type_inst.words[3] != 0;
        if (signed) {
            const val: i32 = @bitCast(literal_words[0]);
            return std.fmt.allocPrint(alloc, "{d}", .{val});
        } else return std.fmt.allocPrint(alloc, "{d}u", .{literal_words[0]});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{literal_words[0]});
}

fn getDecVal(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decs.get(id) orelse return null;
    for (list.items) |e| {
        if (e.decoration == dec and e.extra.len > 0) return e.extra[0];
    }
    return null;
}

fn hasDec(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) bool {
    const list = decs.get(id) orelse return false;
    for (list.items) |e| {
        if (e.decoration == dec) return true;
    }
    return false;
}

/// The GLSL interpolation-qualifier prefix for a varying (`flat ` / `noperspective `,
/// else "" for the default `smooth`). Flat (no interpolation) and NoPerspective (linear)
/// are mutually exclusive; Flat wins if both are set. Matches spirv-cross. (#475)
/// Centroid/Sample are orthogonal auxiliary qualifiers — handled separately if added.
/// GLSL shadow-compare coord constructor + coord swizzle for an OpImageSampleDref*
/// instruction. The compare coordinate packs the texture coordinate (plus an array
/// layer, if any) and the depth-reference scalar, so it is `vecN(coord.<leading>, dref)`.
/// The constructor WIDTH and the leading-component count are derived from the sampler's
/// OpTypeImage Dim/Arrayed behind the sampled image -- NOT the coord width. A glslang
/// producer packs the dref INTO the coord (vec3 for a 2D shadow), so reading the coord
/// width double-counts the dref (a vec4 where vec3 is needed). The leading coord
/// components are the texture coords in both producer encodings (glslang appends dref;
/// zioshade keeps it separate), so swizzling them is producer-independent. A 2D shadow
/// -> vec3(coord.xy, dref); a 2D-array/cube shadow -> vec4(coord.xyz, dref). (#170)
const ShadowCoord = struct { ctor: []const u8, swizzle: []const u8 };
fn shadowSwizzle(n: u32) []const u8 {
    return switch (n) {
        1 => ".x",
        2 => ".xy",
        3 => ".xyz",
        else => "",
    };
}
/// Resolve the OpTypeImage behind a sampled-image VALUE `id` (an OpSampledImage or
/// OpLoad result), unwrapping its result type's OpTypeSampledImage wrapper. Mirrors
/// the MSL backend's imageValueDim resolution. Returns null if unreachable.
fn resolveSampledImageType(m: *const ParsedModule, sampled_image_id: u32) ?Instruction {
    const vdef = getDef(m, sampled_image_id) orelse return null;
    if (vdef.words.len < 2) return null;
    var tinst = getDef(m, vdef.words[1]) orelse return null;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(m, tinst.words[2]) orelse return null;
    }
    if (tinst.op != .TypeImage) return null;
    return tinst;
}
fn glslShadowCoordCtor(m: *const ParsedModule, sampled_image_id: u32, coord_id: u32) ShadowCoord {
    // Leading coord components = spatial coords (by Dim) + array layer (if Arrayed).
    // 1D=1, 2D=2, Cube=3; Rect/unknown default to a 2D shape. Cube-arrayed shadow
    // needs a vec4 coord + a SEPARATE ref (samplerCubeArrayShadow takes (vec4, float)),
    // so the packed vecN(coord, dref) form does not fit -- clamp so we never emit a
    // 5-wide ctor. Rare and not in the corpus.
    var leading: u32 = 2; // 2D default
    if (resolveSampledImageType(m, sampled_image_id)) |img| {
        if (img.words.len >= 4) {
            const spatial: u32 = switch (img.words[3]) {
                0 => 1, // 1D
                1 => 2, // 2D
                3 => 3, // Cube
                else => 2, // Rect/unknown -> 2D-shaped
            };
            const arrayed: u32 = if (img.words.len > 5 and img.words[5] == 1) 1 else 0;
            leading = if (spatial + arrayed > 3) 3 else spatial + arrayed;
        }
    }
    const ctor: []const u8 = switch (leading + 1) {
        2 => "vec2",
        3 => "vec3",
        else => "vec4",
    };
    // A scalar coord (1D shadow passed as a bare float) takes no swizzle.
    if (getDef(m, coord_id)) |d| {
        if (d.words.len >= 2) {
            if (getDef(m, d.words[1])) |t| {
                if (t.op == .TypeFloat) return .{ .ctor = ctor, .swizzle = "" };
            }
        }
    }
    return .{ .ctor = ctor, .swizzle = shadowSwizzle(leading) };
}

/// Index of the ConstOffset (image-operand bit 0x8) value word for an
/// OpImageSampleDref* instruction. Dref occupies words[5] and the image-operands
/// mask is words[6], so operand values start at words[7]; ConstOffset follows
/// Bias(1 word)/Lod(1)/Grad(2) in ascending bit order. Returns null when
/// ConstOffset is absent or its word is missing. (#170)
fn drefConstOffsetIdx(words: []const u32) ?usize {
    if (words.len <= 6) return null;
    const mask = words[6];
    if (mask & 0x8 == 0) return null;
    var off: usize = 7;
    if (mask & 0x1 != 0) off += 1; // Bias
    if (mask & 0x2 != 0) off += 1; // Lod
    if (mask & 0x4 != 0) off += 2; // Grad
    if (off >= words.len) return null;
    return off;
}

fn glslInterpQual(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32) []const u8 {
    // #475: Centroid/Sample are orthogonal auxiliary qualifiers prefixed before the
    // interp type. GLSL: `centroid noperspective`, `sample flat`, etc. Compose both.
    const aux: []const u8 = if (hasDec(decs, id, .sample)) "sample " else if (hasDec(decs, id, .centroid)) "centroid " else "";
    if (hasDec(decs, id, .flat)) {
        if (aux.len > 0) return if (std.mem.eql(u8, aux, "sample ")) "sample flat " else "centroid flat ";
        return "flat ";
    }
    if (hasDec(decs, id, .no_perspective)) {
        if (aux.len > 0) return if (std.mem.eql(u8, aux, "sample ")) "sample noperspective " else "centroid noperspective ";
        return "noperspective ";
    }
    return aux;
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
/// Single source of truth for the desktop GLSL versions zioshade can emit. ESSL is
/// intentionally excluded (#169). Referenced by both the honest-error gate and the
/// `GlslCompileOptions.version` doc comment so the two cannot drift apart.
pub const supported_glsl_versions = [_]u32{ 330, 400, 410, 420, 430, 440, 450, 460 };

fn isSupportedGlslVersion(v: u32) bool {
    for (supported_glsl_versions) |sv| {
        if (v == sv) return true;
    }
    return false;
}

/// True if `type_id` is a pure-sampler (OpTypeSampler) or pure-texture
/// (OpTypeImage, the `texture2D` half of a Vulkan separate sampler) — NOT a
/// combined OpTypeSampledImage. Unwraps a TypePointer first.
fn isPureSamplerOrTextureType(m: *const ParsedModule, type_id: u32) bool {
    var t = getDef(m, type_id) orelse return false;
    if (t.op == .TypePointer and t.words.len >= 4) {
        t = getDef(m, t.words[3]) orelse return false;
    }
    return t.op == .TypeSampler or t.op == .TypeImage;
}

/// Pre-scan a parsed SPIR-V module for features the GLSL backend cannot emit
/// correctly, and return a named error (honest-error) instead of emitting
/// plausible-but-wrong GLSL. Each guard is narrowly scoped so it never refuses a
/// shader the backend actually handles:
///   * `layout(location=N, component=M)` — no desktop-GLSL component qualifier; the
///     emitted locations overlap. Reuses the MSL backend's error name.
///   * subpassInput (OpTypeImage Dim=SubpassData) — Vulkan-only construct with no
///     desktop-GLSL form (subpassInput/subpassLoad need Vulkan GLSL semantics).
///   * gl_DrawID (BuiltIn draw_index) in a fragment shader — DrawID is a
///     vertex-stage-only builtin; no fragment GLSL declares it under any version.
///   * barycentric coords (BuiltIn BaryCoord*/BaryCoordNoPersp*) — require
///     `pervertexEXT` input arrays the backend does not lower; emitting a scalar
///     `in vec2 vUV;` for a 3-element per-vertex array is plausible-but-wrong.
///   * multisample image + a multisample query (textureSamples/imageSamples) — the
///     MS flag is dropped (sampler2D for sampler2DMS), so the query has no
///     matching overload. An MS image used without such a query still emits valid
///     GLSL, so BOTH must be present.
///   * separate samplers passed through a function parameter, or an array of pure
///     sampler/texture resources — the backend does not combine Vulkan separate
///     sampler+texture, so these produce non-sampler operands to texture() /
///     assignments. A global pure sampler it happens to emit acceptably is NOT
///     refused (e.g. separate-sampler-texture.vk still compiles).
fn checkUnsupportedGlslFeatures(m: *const ParsedModule) !void {
    const is_fragment = m.execution_model == .Fragment;
    var has_ms_image = false;
    var has_query_samples = false;
    for (m.instructions) |inst| {
        if ((inst.op == .Decorate or inst.op == .MemberDecorate) and inst.words.len >= 4) {
            const dec_idx: usize = if (inst.op == .Decorate) 2 else 3;
            if (inst.words[dec_idx] == @intFromEnum(spirv.Decoration.component)) {
                return error.UnsupportedComponentPacking;
            }
        }
        if (inst.op == .TypeImage) {
            if (inst.words.len > 3 and inst.words[3] == 6) return error.UnsupportedSubpassInput; // SubpassData
            if (inst.words.len > 6 and inst.words[6] == 1) has_ms_image = true; // MS
        }
        if (inst.op == .ImageQuerySamples) has_query_samples = true;
        if (inst.op == .Decorate and inst.words.len >= 4 and inst.words[2] == @intFromEnum(spirv.Decoration.built_in)) {
            const bi: spirv.BuiltIn = @enumFromInt(inst.words[3]);
            switch (bi) {
                .draw_index => if (is_fragment) return error.UnsupportedFragmentDrawId,
                .bary_coord_khr, .bary_coord_no_persp_khr => return error.UnsupportedBarycentric,
                else => {},
            }
        }
    }
    if (has_ms_image and has_query_samples) return error.UnsupportedMultisampleImage;
    // Honest-error: 16-bit/8-bit types in stage I/O. The frontend drops 16-bit
    // INPUTS entirely (uint16_t, float16_t) → trivial body → silent-wrong. And
    // 16-bit OUTPUTS (f16vec4) need GL_AMD_gpu_shader_half_float which isn't
    // emitted. Refuse rather than emit plausible-but-wrong output.
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Input and sc != .Output) continue;
        const ptr_def = getDef(m, inst.words[1]) orelse continue;
        if (ptr_def.op != .TypePointer or ptr_def.words.len < 4) continue;
        var ty_id = ptr_def.words[3];
        // Unwrap vectors/arrays to the scalar
        while (true) {
            const td = getDef(m, ty_id) orelse break;
            if (td.op == .TypeVector or td.op == .TypeArray) {
                ty_id = td.words[2];
            } else break;
        }
        const td = getDef(m, ty_id) orelse continue;
        if (td.op == .TypeFloat and td.words.len > 2 and td.words[2] == 16) {
            return error.Unsupported16BitIO;
        }
        if (td.op == .TypeInt and td.words.len > 2 and td.words[2] <= 16) {
            return error.Unsupported16BitIO;
        }
    }
    // Separate samplers: precise failure modes (function param / resource array).
    for (m.instructions) |inst| {
        if (inst.op == .FunctionParameter and inst.words.len >= 2) {
            if (isPureSamplerOrTextureType(m, inst.words[1])) return error.UnsupportedSeparateSamplers;
        }
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .UniformConstant) continue;
            const ptr = getDef(m, inst.words[1]) orelse continue;
            if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
            const pointee = getDef(m, ptr.words[3]) orelse continue;
            if (pointee.op == .TypeArray and pointee.words.len > 2) {
                if (isPureSamplerOrTextureType(m, pointee.words[2])) return error.UnsupportedSeparateSamplers;
            }
        }
    }
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
    // #ladder-phi-hoist: per-compile state (the map borrows THIS call's arena;
    // a stale map from a previous compile segfaults on its freed memory).
    g_predeclared_arm_phis_init = false;
    // #169 (G4): honest-error before doing any work. ESSL is out of scope; the
    // `es` field must not be silently ignored. Only the supported desktop set is
    // accepted — anything else is a hard error rather than an invalid #version.
    if (options.es) return error.EsslUnsupported;
    if (!isSupportedGlslVersion(options.version)) return error.UnsupportedGlslVersion;
    g_int_mix_needed = false; // per-invocation reset (threadlocal)

    // Honest-error: PhysicalStorageBufferAddresses (buffer_reference / physical pointers)
    // has no desktop-GLSL equivalent — the physical-pointer syntax is unrepresentable.
    // Honest-error rather than emit invalid output. (#170)
    {
        var ci: usize = 5; // skip 5-word SPIR-V header
        while (ci + 1 < spirv_words.len) {
            const wc = spirv_words[ci] >> 16;
            if (wc == 0) break;
            if ((spirv_words[ci] & 0xFFFF) == 17) {
                const cap = spirv_words[ci + 1];
                if (cap == 5347) return error.UnsupportedPhysicalStorageBuffer;
                if (cap == 4428 or cap == 4439 or cap == 4437) return error.UnsupportedExtensionCapability;
            }
            ci += wc;
        }
    }

    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V. No-op
    // (byte-identical copy) on already-structured input; on failure fall back to
    // the original words so the backend's own honest-error path is unchanged.
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words) catch null;
    defer if (_norm) |n| alloc.free(n);
    var module = try parseModule(alloc, _norm orelse spirv_words);
    defer module.deinit(alloc);

    // #476: honest-error 64-bit numeric types (32-bit target; silent truncation otherwise).
    switch (common.wide64Type(module.instructions)) {
        .float64 => return error.UnsupportedDoubleType,
        .int64 => return error.UnsupportedInt64Type,
        .none => {},
    }

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
        module.execution_model == .MissKHR or module.execution_model == .CallableKHR)
    {
        return error.CrossCompileUnsupported;
    }

    const entry_id = module.entry_point_id orelse return error.NoEntryPoint;

    // Honest-error pre-scan: features the GLSL backend cannot emit correctly
    // (see checkUnsupportedGlslFeatures) fail here with a named error rather than
    // producing plausible-but-wrong output glslangValidator rejects.
    try checkUnsupportedGlslFeatures(&module);

    // Arena allocator for all backend internals — eliminates individual free() overhead
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = std.AutoHashMap(u32, []const u8).init(aa);
    defer names.deinit();
    var decs = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(aa);
    defer decs.deinit();

    collectNames(aa, &module, &names);
    // Prewrite unique struct names BEFORE any forward-decl emission so two
    // distinct structs sharing one OpName don't collapse (the forward-decl
    // emitter dedups by name and would drop the second's real layout, leaving
    // uses to silently bind the wrong bytes -- #zm0).
    common.commonPrewriteUniqueStructNames(module.instructions, &names, aa, common.commonPassthroughName);
    // Alias const-initialised Private globals to their promoted const literal
    // (the array ConstantComposite is already declared as a global `const`), so
    // `arr[i]` resolves to the literal instead of an undeclared variable (Design A).
    common.aliasConstInitializedPrivateVars(aa, &module, &names);
    // Mangle function-scope ids (Function-class OpVariable or OpFunctionParameter)
    // whose name collides with a GLOBAL variable's -- the only collision that
    // silently shadows (#sid). Scope-aware + block-instance-excluded so it leaves
    // type/variable overlaps (e.g. a UBO block + its instance both "Globals") and
    // block-named instances alone. Runs after aliasConst.
    common.commonPrewriteUniqueLocalVarNames(module.instructions, &names, aa, false);
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
        try w.print("layout(local_size_x = {d}, local_size_y = {d}, local_size_z = {d}) in;\n\n", .{ ls[0], ls[1], ls[2] });
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
        // member zioshade supports as a desktop-GLSL extension) is a BARE scalar/vector/
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
                const elem_tn = try glslType(&module, elem_id, &names, aa);
                try w.print("uniform {s} {s}", .{ elem_tn, cb.name });
                for (dims.items) |d| try w.writeAll(d);
                try w.writeAll(";\n\n");
            } else {
                const tn = try glslType(&module, cb.type_id, &names, aa);
                try w.print("uniform {s} {s};\n\n", .{ tn, cb.name });
            }
            continue;
        }
        const shifted = common.applyBindingShift(cb.binding, options.binding_shift);
        try w.print("layout(binding = {d}, std140) uniform {s}\n{{\n", .{ shifted, cb.name });
        try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa, false);
        try w.print("}} {s}_1;\n\n", .{cb.name});
    }

    // Emit SSBO (storage buffer) declarations. SSBOs are legal in every stage
    // (GLSL 4.30 / GLSL ES 3.10 with shader_storage_buffer_object), not just
    // compute — a StorageBuffer-class block in a fragment shader is declared
    // here too, or its `{instance}.{member}` uses reference an undeclared block.
    {
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
                const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
                if (ptr_inst.op != .TypePointer or ptr_inst.words.len < 4) continue;
                // The pointee may be an array of the block struct (a descriptor array,
                // source `buffer B { ... } name[N];`). Unwrap nested TypeArrays to the
                // block struct for member emission and collect the [N][M] suffix for the
                // instance, so the body's `name[i].member` resolves (#473).
                var pointee_id: u32 = ptr_inst.words[3];
                var dims = std.ArrayList(u8).initCapacity(aa, 16) catch return error.OutOfMemory;
                defer dims.deinit(aa);
                {
                    var pt = getDef(&module, pointee_id);
                    while (pt) |p| {
                        if (p.op != .TypeArray or p.words.len < 4) break;
                        const len_def = getDef(&module, p.words[3]);
                        const n: u32 = if (len_def) |ld| (if ((ld.op == .Constant or ld.op == .SpecConstant) and ld.words.len > 3) ld.words[3] else 0) else 0;
                        dims.print(aa, "[{d}]", .{n}) catch break;
                        pointee_id = p.words[2];
                        pt = getDef(&module, pointee_id);
                    }
                }
                const member_struct = getDef(&module, pointee_id);
                const has_block_struct = member_struct != null and member_struct.?.op == .TypeStruct;
                // Declare any struct types referenced by this block's members (e.g. the
                // element struct of a runtime array `T elems[]`) BEFORE the block, so the
                // struct is not used before it is declared (#418). SSBOs are excluded from
                // the UBO forward-decl pass above, so run it here over the same maps.
                if (has_block_struct) {
                    emitStructForwardDecls(&module, &names, pointee_id, w, aa, &emitted_structs, &emitted_names) catch {};
                }
                try w.print("layout(std430, binding = {d}) buffer {s}\n{{\n", .{ shifted_binding, block_tag });
                // Emit struct members by their ORIGINAL names (`b.lock`) for BOTH SSBO
                // encodings: StorageBuffer-class and old-style Uniform+BufferBlock now both
                // bypass isUniformBlockVar (see structHasBufferBlock there), so the body
                // accesses members as `{instance}.{member}` — declare them to match. (#296)
                const use_original = true;
                if (has_block_struct) {
                    try emitStructMembers(&module, &names, pointee_id, name, w, aa, use_original);
                }
                try w.print("}} {s}{s};\n\n", .{ name, dims.items });
            }
        }
    }

    // Emit push-constant blocks. Desktop GL has no `push_constant` qualifier, so
    // (like SPIRV-Cross) a PushConstant-storage block lowers to a plain std140
    // `uniform` block with its ORIGINAL member names and instance = the var name;
    // the body already accesses `{instance}.{member}`. Push constants carry no
    // binding/set, so no `layout(binding=)`. Without this the block is declared
    // nowhere and its uses reference an undeclared identifier. PushConstant is not
    // a Uniform storage class, so it is never on the cbuffer path (no double-emit).
    {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .PushConstant) continue;
            const rid = inst.words[2];
            const name = names.get(rid) orelse continue;
            const block_tag = std.fmt.allocPrint(aa, "{s}_block", .{name}) catch return error.OutOfMemory;
            const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
            const has_block_struct = ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4;
            if (has_block_struct) {
                emitStructForwardDecls(&module, &names, ptr_inst.words[3], w, aa, &emitted_structs, &emitted_names) catch {};
            }
            try w.print("layout(std140) uniform {s}\n{{\n", .{block_tag});
            if (has_block_struct) {
                try emitStructMembers(&module, &names, ptr_inst.words[3], name, w, aa, true);
            }
            try w.print("}} {s};\n\n", .{name});
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
            const itype = if (std.mem.eql(u8, dim_str, "Buffer")) (if (tex.is_uint) "uimageBuffer" else if (tex.is_int) "iimageBuffer" else "imageBuffer") else std.fmt.allocPrint(aa, "{s}image{s}", .{ if (tex.is_uint) "u" else if (tex.is_int) "i" else "", dim_str }) catch "image2D";
            try w.print("layout(binding = {d}, {s}) uniform {s} {s}{s};\n", .{ tex_shifted, tex.format_str, itype, tex.name, arr });
        } else {
            // A shadow/depth sampler carries the `Shadow` suffix (sampler2DShadow,
            // sampler2DArrayShadow, samplerCubeShadow); it is always float, so the
            // u/i-sampler prefixes never combine with it.
            const shadow_suffix: []const u8 = if (tex.shadow) "Shadow" else "";
            // Multisampled samplers insert "MS" between the dim spelling and any
            // "Array" suffix (sampler2DMS, sampler2DMSArray). GLSL has no 1D/3D/Cube
            // MS sampler, so this only fires for the valid 2D case; MS storage images
            // do not exist either, so this is sampler-path only. Built from the raw
            // tex.dim_str (before the arrayed "Array" suffix) so the order is
            // dim+MS+Array, matching the GLSL spelling.
            const ms_dim_str: []const u8 = if (tex.is_ms) (if (tex.arrayed) (std.fmt.allocPrint(aa, "{s}MSArray", .{tex.dim_str}) catch dim_str) else (std.fmt.allocPrint(aa, "{s}MS", .{tex.dim_str}) catch dim_str)) else dim_str;
            const stype = if (tex.is_uint) std.fmt.allocPrint(aa, "usampler{s}", .{ms_dim_str}) catch "usampler2D" else if (tex.is_int) std.fmt.allocPrint(aa, "isampler{s}", .{ms_dim_str}) catch "isampler2D" else std.fmt.allocPrint(aa, "sampler{s}{s}", .{ ms_dim_str, shadow_suffix }) catch "sampler2D";
            try w.print("layout(binding = {d}) uniform {s} {s}{s};\n", .{ tex_shifted, stype, tex.name, arr });
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
            } else if (std.mem.eql(u8, type_str, "int")) {
                // #475: a signed-int default with the high bit set (e.g. -1) must print
                // as the negative value, not the raw u32 (4294967295) — glslang rejects
                // the out-of-range int literal.
                const iv: i32 = @bitCast(default_val);
                try w.print("layout(constant_id = {d}) const {s} {s} = {d};\n", .{ sid, type_str, name, iv });
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
        if (inst.op != .SpecConstantOp or inst.words.len < 5) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try glslType(&module, type_id, &names, aa);
        // Unary ops (5 words): SNegate(126), FNegate(127), Not(200). #475
        if (inst.words.len == 5) {
            const op0 = names.get(inst.words[4]) orelse continue;
            const uop: ?[]const u8 = switch (opcode_lit) {
                126, 127 => "-",
                200 => "~",
                else => null,
            };
            if (uop) |u| try w.print("const {s} {s} = {s}({s});\n", .{ type_str, name, u, op0 });
            continue;
        }
        // OpSelect (ternary, 7 words): const T name = cond ? tv : fv; (#499)
        if (opcode_lit == 169 and inst.words.len == 7) {
            const cond = names.get(inst.words[4]) orelse continue;
            const tv = names.get(inst.words[5]) orelse continue;
            const fv = names.get(inst.words[6]) orelse continue;
            try w.print("const {s} {s} = ({s}) ? ({s}) : ({s});\n", .{ type_str, name, cond, tv, fv });
            continue;
        }
        // Binary ops (6 words). #475: extended from just +,-,*,/ to include modulo,
        // shifts, and bitwise ops (all glslang-reachable from spec-constant expressions).
        // #499: integer/float comparisons (result type is bool).
        const op_str: ?[]const u8 = switch (opcode_lit) {
            128, 129 => "+", // IAdd / FAdd
            130, 131 => "-", // ISub / FSub
            132, 133 => "*", // IMul / FMul
            134, 135, 136 => "/", // UDiv / SDiv / FDiv
            137, 138, 139, 140, 141 => "%", // UMod / SRem / SMod / FRem / FMod
            194, 195 => ">>", // ShiftRightLogical / ShiftRightArithmetic
            196 => "<<", // ShiftLeftLogical
            197 => "|", // BitwiseOr
            198 => "^", // BitwiseXor
            199 => "&", // BitwiseAnd
            170, 180, 181 => "==", // IEqual / FOrdEqual / FUnordEqual
            171, 182, 183 => "!=", // INotEqual / FOrdNotEqual / FUnordNotEqual
            172, 173, 186, 187 => ">", // U/SGreaterThan, FOrd/UnordGreaterThan
            174, 175, 190, 191 => ">=", // U/SGreaterThanEqual, FOrd/UnordGreaterThanEqual
            176, 177, 184, 185 => "<", // U/SLessThan, FOrd/UnordLessThan
            178, 179, 188, 189 => "<=", // U/SLessThanEqual, FOrd/UnordLessThanEqual
            else => null,
        };
        const op = op_str orelse continue;
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
            try w.print("const {s} {s}{s} = {{", .{ base_type, name, arr_suffix.items });
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
            try w.print("const {s} {s} = {{", .{ struct_name, name });
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
    // Structs that appear only as SSA VALUES (an inlined function's struct locals
    // become OpCompositeConstruct/OpFunctionCall results, not OpVariables) are
    // missed by the OpVariable scan above; declare them too.
    for (module.instructions) |inst| {
        if (common.structValueTypeId(&module, inst)) |sid| {
            emitOneStructForwardDecl(&module, &names, sid, w, aa, &local_structs_glsl, &emitted_names) catch {};
        }
    }
    if (local_structs_glsl.count() > 0) try w.writeAll("\n");

    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| {
        if (inst.op == .Function and inst.words.len > 2) try func_ids.append(aa, inst.words[2]);
    }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer {
        var it = out_param_info.iterator();
        while (it.next()) |e| e.value_ptr.deinit(aa);
        out_param_info.deinit();
    }
    common.detectOutParams(module.instructions, module.id_defs, entry_id, &out_param_info, aa);

    // Declare stage in/out varyings and mutable Private globals at file scope BEFORE
    // any function body — a helper may reference a stage input or a global, and the
    // entry point (which used to emit these) is written last. (triple-nested-functions)
    // `needs_version` is raised by emitModuleGlobals when it emits constructs that
    // require a higher #version (interface blocks need 450); the post-pass below
    // rewrites the #version line upward once the body is known.
    var needs_version: u32 = options.version;
    try emitModuleGlobals(&module, &decs, &names, options.version, w, aa, &emitted_structs, &emitted_names, &needs_version);

    // Forward-declare every non-entry function before any body, so a call to a
    // function defined LATER resolves — mutual recursion (helperA <-> helperB) and
    // any forward reference. GLSL requires a prototype before use, and the source's
    // prototypes are not preserved in SPIR-V. A prototype plus a matching definition
    // is valid GLSL, so this is emitted unconditionally for all helpers.
    //
    // The entry is pinned to `main` in emitFunction; a helper whose OpName is also
    // `main` would collide with it (redefinition). Rename such helpers first
    // (spirv-cross does the same when it re-homes a non-main entry).
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue;
        if (std.mem.eql(u8, names.get(fid) orelse "", "main")) {
            const rn = aa.dupe(u8, "main_1") catch continue;
            if (names.fetchPut(fid, rn) catch null) |old| aa.free(old.value);
        }
    }
    var emitted_any_proto = false;
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue;
        try emitFunctionPrototype(&module, &names, fid, &out_param_info, w, aa);
        emitted_any_proto = true;
    }
    if (emitted_any_proto) try w.writeAll("\n");
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue;
        try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info);
    }
    try emitFunction(&module, &names, &decs, entry_id, w, aa, true, &out_param_info);
    try spliceRequiredVersion(&output, alloc, options.version, needs_version);
    try spliceRequiredExtensions(&output, alloc);
    output_owned = false;
    return output.toOwnedSlice(alloc);
}

// ---- Parser (identical to HLSL backend) ----
fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;
    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch return error.OutOfMemory;
    errdefer instructions.deinit(alloc);
    // Use flat array for ID lookups — O(1) without hashing. Reject an absurd id
    // bound first: a hostile ~4-billion bound would make this allocation and its
    // zero-fill hang. A real module never has more ids than words.
    const bound = if (words.len > 3) words[3] else 0;
    if (bound > words.len) return error.InvalidSpirv;
    const id_defs = try alloc.alloc(?usize, bound);
    // The parse loop below can reject a malformed instruction; without this the
    // id table leaks on every rejected module.
    errdefer alloc.free(id_defs);
    @memset(id_defs, null);
    var i: usize = 5;
    while (i < words.len) {
        const hw = words[i];
        const wc: u16 = @intCast(hw >> 16);
        const oc: u16 = @truncate(hw & 0xFFFF);
        if (wc == 0) return error.InvalidSpirv;
        if (i + wc > words.len) return error.InvalidSpirvTruncated;
        const op: spirv.Op = @enumFromInt(oc);
        // Reject an instruction shorter than its opcode's spec minimum, so the
        // emit arms below never index past the end of `inst.words`. (Shared
        // table, see common.minWordCount.)
        if (common.minWordCount(op)) |min| {
            if (wc < min) return error.InvalidSpirvTruncated;
        }
        const iw = words[i .. i + wc];
        if (resultIdFromOp(op, iw)) |id| {
            if (id < bound) id_defs[id] = instructions.items.len;
        }
        instructions.append(alloc, .{ .op = op, .words = iw }) catch return error.OutOfMemory;
        i += wc;
    }
    // Not `catch instructions.items`: that hands back the backing buffer, whose
    // capacity is larger than items.len, and ParsedModule.deinit would then free
    // a slice of the wrong length.
    const owned = instructions.toOwnedSlice(alloc) catch return error.OutOfMemory;
    var module = ParsedModule{ .instructions = owned, .id_defs = id_defs };
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) {
            if (module.entry_point_id == null) {
                module.execution_model = @enumFromInt(inst.words[1]);
                module.entry_point_id = inst.words[2];
            }
        }
        if (inst.op == .ExecutionMode and inst.words.len >= 3) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSize and inst.words.len >= 6) module.local_size = .{ inst.words[3], inst.words[4], inst.words[5] };
            // #475: LocalSizeId (spec-constant workgroup size) — operands are OpSpecConstant
            // result IDs; resolve each to its default so layout(local_size_x=...) is right.
            if (mode == .LocalSizeId and inst.words.len >= 6) module.local_size = .{
                glslSpecConstantDefault(&module, inst.words[3], 1),
                glslSpecConstantDefault(&module, inst.words[4], 1),
                glslSpecConstantDefault(&module, inst.words[5], 1),
            };
        }
        // OpExecutionModeId (331): id-operand form. LocalSizeId here carries spec-constant
        // RESULT IDs (the valid form for compute). Resolve via common.specConstantDefault
        // (evaluates OpSpecConstantOp, e.g. SC*2, incl. plain OpConstant operands) so
        // layout(local_size_x=...) emits the intended workgroup size instead of silently
        // 1x1x1. (e54.4.8 cross-backend S3; #514 fixed WGSL.)
        if (inst.op == .ExecutionModeId and inst.words.len >= 6) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSizeId) module.local_size = .{
                common.specConstantDefault(&module, inst.words[3], 1),
                common.specConstantDefault(&module, inst.words[4], 1),
                common.specConstantDefault(&module, inst.words[5], 1),
            };
        }
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
    // #carry-ops: OpIAddCarry (149) / OpISubBorrow (150) / OpUMulExtended (151)
    // define a result at words[2]; the spirv.Op enum is non-exhaustive and does
    // not name them (same raw-opcode indexing as common's shared table, #170).
    {
        const opc = @intFromEnum(op);
        if (opc == 149 or opc == 150 or opc == 151) return if (words.len > 2) words[2] else null;
    }
    return switch (op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix, .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray, .TypeStruct, .TypePointer, .TypeFunction, .TypeForwardPointer, .TypeAccelerationStructureKHR, .TypeRayQueryKHR, .TypeTensorARM => if (words.len > 1) words[1] else null,
        .ConstantTrue, .ConstantFalse, .Constant, .ConstantComposite, .ConstantNull, .SpecConstant, .SpecConstantTrue, .SpecConstantFalse, .SpecConstantComposite, .SpecConstantOp, .Undef => if (words.len > 2) words[2] else null,
        .Variable, .Function, .FunctionParameter => if (words.len > 2) words[2] else null,
        .Load, .AccessChain, .CompositeConstruct, .CompositeExtract, .CompositeInsert, .VectorShuffle, .SampledImage, .ImageSampleImplicitLod, .ImageSampleExplicitLod, .ImageFetch, .ImageGather, .ImageQuerySizeLod, .ImageQuerySize, .ImageTexelPointer, .FunctionCall, .CopyObject, .Phi, .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU, .UConvert, .SConvert, .FConvert, .Bitcast, .SNegate, .FNegate, .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul, .UDiv, .SDiv, .FDiv, .UMod, .SRem, .SMod, .FRem, .FMod, .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix, .Dot, .Transpose, .OuterProduct, .Select, .LogicalOr, .LogicalAnd, .LogicalNot, .LogicalEqual, .LogicalNotEqual, .IEqual, .INotEqual, .UGreaterThan, .SGreaterThan, .UGreaterThanEqual, .SGreaterThanEqual, .ULessThan, .SLessThan, .ULessThanEqual, .SLessThanEqual, .FOrdEqual, .FOrdNotEqual, .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual, .FUnordEqual, .FUnordNotEqual, .FUnordLessThan, .FUnordGreaterThan, .FUnordLessThanEqual, .FUnordGreaterThanEqual, .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical, .BitwiseOr, .BitwiseXor, .BitwiseAnd, .Not, .BitReverse, .BitCount, .BitFieldInsert, .BitFieldSExtract, .BitFieldUExtract, .IsNan, .IsInf, .All, .Any, .DPdx, .DPdy, .Fwidth, .DPdxFine, .DPdyFine, .FwidthFine, .DPdxCoarse, .DPdyCoarse, .FwidthCoarse, .VectorExtractDynamic, .ExtInst, .OpImage, .AtomicIAdd, .AtomicISub, .AtomicExchange, .AtomicSMin, .AtomicUMin, .AtomicSMax, .AtomicUMax, .AtomicAnd, .AtomicOr, .AtomicXor, .ImageSampleDrefImplicitLod, .ImageSampleDrefExplicitLod, .ImageSampleProjImplicitLod, .ImageSampleProjExplicitLod, .ImageSampleProjDrefImplicitLod, .ImageSampleProjDrefExplicitLod, .ImageDrefGather, .ImageQueryLod, .ImageQueryLevels, .ImageQuerySamples, .ImageRead, .AtomicCompareExchange, .AtomicFAddEXT, .ArrayLength => if (words.len > 2) words[2] else null,
        // #subgroup-operand: subgroup ops define a result at words[2]; without
        // this the result was never pre-named, so the emit handler's `orelse "v"`
        // fallback collided with a user variable and the downstream store dropped
        // the value. Mirrors common.resultIdFromOp.
        .GroupNonUniformElect, .GroupNonUniformAll, .GroupNonUniformAny, .GroupNonUniformAllEqual, .GroupNonUniformBroadcast, .GroupNonUniformBroadcastFirst, .GroupNonUniformBallot, .GroupNonUniformIAdd, .GroupNonUniformFAdd, .GroupNonUniformIMul, .GroupNonUniformFMul, .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin, .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax, .GroupNonUniformBitwiseAnd, .GroupNonUniformBitwiseOr, .GroupNonUniformBitwiseXor, .GroupNonUniformLogicalAnd, .GroupNonUniformLogicalOr, .GroupNonUniformShuffle, .GroupNonUniformShuffleXor, .GroupNonUniformShuffleUp, .GroupNonUniformShuffleDown, .SubgroupAllKHR, .SubgroupAnyKHR => if (words.len > 2) words[2] else null,
        else => null,
    };
}

// ---- Collection passes (identical logic to HLSL) ----
fn collectNames(alloc: std.mem.Allocator, m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    for (m.instructions) |inst| {
        if (inst.op == .Name and inst.words.len >= 3) {
            const id = inst.words[1];
            const ns = parseLitStr(alloc, inst.words[2..]) catch continue;
            const san = sanitizeName(alloc, ns) catch {
                names.put(id, ns) catch {};
                continue;
            };
            alloc.free(ns);
            names.put(id, san) catch {};
        }
        if (inst.op == .Constant and inst.words.len > 3) {
            const rid = inst.words[2];
            const ti = getDef(m, inst.words[1]);
            if (ti) |t| {
                const lit = constantLiteral(alloc, t, inst.words[3..]) catch continue;
                if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                continue;
            }
        }
        if (inst.op == .ConstantTrue and inst.words.len > 2) {
            const l = alloc.dupe(u8, "true") catch continue;
            if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value);
            continue;
        }
        if (inst.op == .ConstantFalse and inst.words.len > 2) {
            const l = alloc.dupe(u8, "false") catch continue;
            if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value);
            continue;
        }
        // OpUndef (module-scope, per SPIR-V spec) is named by collectNames but every
        // emit switch only visits module-scope OpVariable, so it was referenced at use
        // sites with no declaration -> undeclared identifier. Fold it to a zero literal
        // inline, exactly like OpConstantNull (a semantically identical zero-of-type),
        // so each use site resolves to the literal. Matches spirv-cross (zero-inits undef).
        if ((inst.op == .ConstantNull or inst.op == .Undef) and inst.words.len > 2) {
            const tn = glslType(m, inst.words[1], names, alloc) catch "float";
            const l = std.fmt.allocPrint(alloc, "{s}(0)", .{tn}) catch continue;
            if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value);
            continue;
        }
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
                            if (c != first) {
                                all_same = false;
                                break;
                            }
                        }
                    }
                    const vt = glslType(m, inst.words[1], names, alloc) catch "vec4";
                    if (all_same and constituents.len > 0) {
                        // Splat: vec3(1.0) instead of vec3(1.0, 1.0, 1.0)
                        const val = names.get(constituents[0]) orelse "0.0";
                        const lit = std.fmt.allocPrint(alloc, "{s}({s})", .{ vt, val }) catch continue;
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
        if (resultIdFromOp(inst.op, inst.words)) |rid| {
            if (!names.contains(rid)) {
                const name = std.fmt.allocPrint(alloc, "v{}", .{counter}) catch continue;
                counter += 1;
                names.put(rid, name) catch {};
            }
        }
    }

    // Deduplicate Function-scoped variable names
    // Collect all Function-scoped variable IDs grouped by name
    var name_groups = std.StringHashMapUnmanaged(std.ArrayList(u32)).empty;
    defer {
        var dgi = name_groups.iterator();
        while (dgi.next()) |e| {
            alloc.free(e.key_ptr.*);
            e.value_ptr.deinit(alloc);
        }
        name_groups.deinit(alloc);
    }
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
                        const dgop = name_groups.getOrPut(alloc, dvn_copy) catch {
                            alloc.free(dvn_copy);
                            continue;
                        };
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
    for (m.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3) {
            const id = inst.words[1];
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            const extra = if (inst.words.len > 3) inst.words[3..] else &[_]u32{};
            const gop = try decs.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(DecorationEntry).empty;
            try gop.value_ptr.append(alloc, .{ .decoration = dec, .extra = extra });
        }
    }
}

fn collectResources(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), cb: *std.ArrayList(CbufferDecl), tex: *std.ArrayList(TextureDecl), alloc: std.mem.Allocator) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const rt = inst.words[1];
        const rid = inst.words[2];
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        const pi = getDef(m, rt) orelse continue;
        if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        switch (sc) {
            // Exclude SSBOs from the cbuffer list. `BufferBlock` is decorated on the STRUCT
            // TYPE (`structHasBufferBlock(pt)`) — the variable-id check `hasDec(rid,…)` is a
            // defensive no-op for spec-conformant SPIR-V but kept for any producer that mis-
            // decorates the variable. Excluded in every stage: the SSBO emission loop now runs
            // in all stages, so an old-style SSBO is declared there, never on the uniform path.
            .Uniform => {
                if (hasDec(decs, rid, .buffer_block) or structHasBufferBlock(m, pt)) continue;
                const binding = getDecVal(decs, rid, .binding) orelse 0;
                // GLSL uniform blocks need a non-empty instance (and block-type) name; an unnamed
                // SPIR-V instance (OpName "") yields cb.name = "" -> an anonymous block AND, across
                // multiple blocks, colliding `{name}_1` instances. Synthesize a stable name (struct
                // type name, else binding-derived) and publish it back into `names` so the block
                // declaration AND every body reference (buildAccessExpr's `{p}_1.{p}_m{idx}`) agree.
                const ub_inst_nm: []const u8 = blk: {
                    if (names.get(rid)) |n| if (n.len > 0) break :blk n;
                    if (names.get(pt)) |tn| if (tn.len > 0) break :blk tn;
                    break :blk std.fmt.allocPrint(alloc, "_ub{d}", .{binding}) catch "_ub";
                };
                names.put(rid, ub_inst_nm) catch {};
                cb.append(alloc, .{ .name = ub_inst_nm, .type_id = pt, .binding = binding }) catch {};
            },
            .UniformConstant => {
                var pei = getDef(m, pt) orelse continue;
                const binding = getDecVal(decs, rid, .binding) orelse 0;
                const name = names.get(rid) orelse "tex";
                var arr_sz: u32 = 0;
                if (pei.op == .TypeArray and pei.words.len > 3) {
                    const li = getDef(m, pei.words[3]);
                    arr_sz = if (li != null and li.?.op == .Constant and li.?.words.len > 3) li.?.words[3] else 0;
                    pei = getDef(m, pei.words[2]) orelse continue;
                }
                switch (pei.op) {
                    .TypeSampledImage => {
                        const si_img = if (pei.words.len > 2) getDef(m, pei.words[2]) else null;
                        const si_st = if (si_img != null and si_img.?.words.len > 2) getDef(m, si_img.?.words[2]) else null;
                        const si_uint = si_st != null and si_st.?.op == .TypeInt and si_st.?.words.len > 3 and si_st.?.words[3] == 0;
                        const si_int = si_st != null and si_st.?.op == .TypeInt and si_st.?.words.len > 3 and si_st.?.words[3] != 0;
                        const si_dim: []const u8 = blk: {
                            if (si_img != null and si_img.?.words.len > 3) {
                                break :blk switch (si_img.?.words[3]) {
                                    0 => "1D",
                                    1 => "2D",
                                    2 => "3D",
                                    3 => "Cube",
                                    4 => "Rect",
                                    5 => "Buffer",
                                    6 => "SubpassData",
                                    else => "2D",
                                };
                            }
                            break :blk "2D";
                        };
                        const si_arrayed = si_img != null and si_img.?.words.len > 5 and si_img.?.words[5] == 1;
                        // OpTypeImage Depth operand (words[4]) == 1 marks a shadow/depth
                        // sampler (sampler2DShadow etc.). Dropping it degraded the
                        // declaration to a plain sampler2D, which glslang rejects against
                        // the Dref sample/gather calls the body emits.
                        const si_shadow = si_img != null and si_img.?.words.len > 4 and si_img.?.words[4] == 1;
                        // OpTypeImage MS operand (words[6]) == 1 marks a multisampled image
                        // (sampler2DMS / sampler2DMSArray). Dropping it degraded the decl to a
                        // plain sampler2D and made the per-sample texelFetch reads wrong.
                        const si_ms = si_img != null and si_img.?.words.len > 6 and si_img.?.words[6] == 1;
                        tex.append(alloc, .{ .name = name, .binding = binding, .is_uint = si_uint, .is_int = si_int, .dim_str = si_dim, .array_size = arr_sz, .arrayed = si_arrayed, .shadow = si_shadow, .is_ms = si_ms }) catch {};
                    },
                    .TypeImage => {
                        const sampled: u32 = if (pei.words.len > 7) pei.words[7] else 0;
                        const is_storage = sampled == 2;
                        const st_inst = if (pei.words.len > 2) getDef(m, pei.words[2]) else null;
                        const is_uint = st_inst != null and st_inst.?.op == .TypeInt and st_inst.?.words.len > 3 and st_inst.?.words[3] == 0;
                        const is_int = st_inst != null and st_inst.?.op == .TypeInt and st_inst.?.words.len > 3 and st_inst.?.words[3] != 0;
                        const fmt: []const u8 = blk: {
                            if (pei.words.len > 8) {
                                break :blk switch (pei.words[8]) {
                                    0 => "rgba8f",
                                    1 => "rgba32f",
                                    2 => "rgba16f",
                                    3 => "r32f",
                                    4 => "rgba8",
                                    5 => "rgba8_snorm",
                                    6 => "rg32f",
                                    7 => "rg16f",
                                    8 => "r11f_g11f_b10f",
                                    9 => "r16f",
                                    10 => "rgba16",
                                    11 => "rgb10_a2",
                                    12 => "rg16",
                                    13 => "rg8",
                                    14 => "r16",
                                    15 => "r8",
                                    16 => "rgba16_snorm",
                                    17 => "rg16_snorm",
                                    18 => "rg8_snorm",
                                    19 => "r16_snorm",
                                    20 => "r8_snorm",
                                    21 => "rgba32i",
                                    22 => "rgba16i",
                                    23 => "rgba8i",
                                    24 => "r32i",
                                    25 => "rg32i",
                                    26 => "rg16i",
                                    27 => "rg8i",
                                    28 => "r16i",
                                    29 => "r8i",
                                    30 => "rgba32ui",
                                    31 => "rgba16ui",
                                    32 => "rgba8ui",
                                    33 => "r32ui",
                                    34 => "rgb10_a2ui",
                                    35 => "rg32ui",
                                    36 => "rg16ui",
                                    37 => "rg8ui",
                                    38 => "r16ui",
                                    39 => "r8ui",
                                    else => "rgba8f",
                                };
                            }
                            break :blk "rgba8f";
                        };
                        const dim: []const u8 = blk: {
                            if (pei.words.len > 3) {
                                break :blk switch (pei.words[3]) {
                                    0 => "1D",
                                    1 => "2D",
                                    2 => "3D",
                                    3 => "Cube",
                                    4 => "Rect",
                                    5 => "Buffer",
                                    6 => "SubpassData",
                                    else => "2D",
                                };
                            }
                            break :blk "2D";
                        };
                        const img_arrayed = pei.words.len > 5 and pei.words[5] == 1;
                        const img_ms = pei.words.len > 6 and pei.words[6] == 1;
                        tex.append(alloc, .{ .name = name, .binding = binding, .is_storage = is_storage, .format_str = fmt, .dim_str = dim, .is_uint = is_uint, .is_int = is_int, .array_size = arr_sz, .arrayed = img_arrayed, .is_ms = img_ms }) catch {};
                    },
                    else => {},
                }
            },
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
/// True if member `member_idx` of `struct_id` carries `OpMemberDecorate ... RowMajor`.
/// A UBO/SSBO matrix member so decorated is stored row-major; GLSL defaults to
/// column-major, so without an explicit `layout(row_major)` the bytes are read as the
/// transpose (silent-wrong). Mirrors the MSL/HLSL/WGSL backends, which all honor it.
fn glslMemberIsRowMajor(m: *const ParsedModule, struct_id: u32, member_idx: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 4) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        if (@as(spirv.Decoration, @enumFromInt(inst.words[3])) == .row_major) return true;
    }
    return false;
}

/// True if `type_id` is, or transitively contains (through TypeArray /
/// TypeRuntimeArray element types or TypeStruct members), a matrix member that
/// carries `OpMemberDecorate ... RowMajor`. The drill in `emitStructMembers`
/// otherwise stops at the struct boundary: a RowMajor on a matrix INSIDE a
/// struct-typed UBO/SSBO block member is dropped, so the bytes are read as the
/// transpose (silent-wrong). GLSL `layout(row_major)` on a BLOCK member of
/// struct type propagates into the struct's matrix members (it is valid on
/// block members, NOT on plain struct members, so the struct forward decl is
/// left bare). Works for square AND non-square matrices: in GLSL `row_major` is
/// purely a byte-layout qualifier and indexing stays column-major (matching
/// SPIR-V), so no transpose or dimension swap is needed.
fn glslStructTypeNeedsRowMajor(m: *const ParsedModule, type_id: u32) bool {
    const ti = getDef(m, type_id) orelse return false;
    switch (ti.op) {
        .TypeArray, .TypeRuntimeArray => {
            if (ti.words.len < 3) return false;
            return glslStructTypeNeedsRowMajor(m, ti.words[2]);
        },
        .TypeStruct => {
            // SPIR-V value struct types are acyclic (a struct cannot contain
            // itself by value, only via a pointer), so this recursion terminates.
            for (ti.words[2..], 0..) |member_tid, mi| {
                if (glslMemberIsRowMajor(m, type_id, @intCast(mi))) return true;
                if (glslStructTypeNeedsRowMajor(m, member_tid)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn emitStructMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, cb_name: []const u8, w: anytype, alloc: std.mem.Allocator, original_names: bool) !void {
    const inst = getDef(m, struct_id) orelse return;
    if (inst.op != .TypeStruct) return;
    for (inst.words[2..], 0..) |mt_id, mi| {
        var mbuf: [32]u8 = undefined;
        const mname: []const u8 = if (original_names) getMemberName(m, struct_id, @intCast(mi), &mbuf) else "";
        // #472-audit: honor RowMajor. Only matrices (incl. arrays of matrices) carry
        // this decoration; a plain member without it stays column-major (the default).
        // A struct-typed block member may itself enclose a RowMajor matrix (the
        // decoration sits on the inner struct's matrix member); without recursing,
        // the row-major layout is dropped (silent-wrong transpose read).
        const rm: []const u8 = if (glslMemberIsRowMajor(m, struct_id, @intCast(mi)) or
            glslStructTypeNeedsRowMajor(m, mt_id)) "layout(row_major) " else "";
        const mti = getDef(m, mt_id);
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                // Multi-dim array member (e.g. mat2x3 var[3][4]): walk nested
                // TypeArrays, emit ALL dimensions [N][M]..., element type = the leaf.
                // (glslType alone unwraps to the leaf, dropping every dimension.)
                var dims = std.ArrayList(u8).initCapacity(alloc, 16) catch return error.OutOfMemory;
                defer dims.deinit(alloc);
                var cur_id = mt_id;
                var elem_id = mi2.words[2];
                while (true) {
                    const cur = getDef(m, cur_id) orelse break;
                    if (cur.op != .TypeArray or cur.words.len <= 3) break;
                    const li = getDef(m, cur.words[3]);
                    const lv: u32 = if (li) |l| (if ((l.op == .Constant or l.op == .SpecConstant) and l.words.len > 3) l.words[3] else 1) else 1;
                    dims.print(alloc, "[{d}]", .{lv}) catch break;
                    elem_id = cur.words[2];
                    cur_id = cur.words[2];
                }
                const et = try glslType(m, elem_id, names, alloc);
                if (original_names) try w.print("    {s}{s} {s}{s};\n", .{ rm, et, mname, dims.items }) else try w.print("    {s}{s} {s}_m{d}{s};\n", .{ rm, et, cb_name, mi, dims.items });
                continue;
            }
            if (mi2.op == .TypeRuntimeArray and mi2.words.len > 2) {
                const et = try glslType(m, mi2.words[2], names, alloc);
                if (original_names) try w.print("    {s}{s} {s}[];\n", .{ rm, et, mname }) else try w.print("    {s}{s} {s}_m{d}[];\n", .{ rm, et, cb_name, mi });
                continue;
            }
        }
        const mt = try glslType(m, mt_id, names, alloc);
        if (original_names) try w.print("    {s}{s} {s};\n", .{ rm, mt, mname }) else try w.print("    {s}{s} {s}_m{d};\n", .{ rm, mt, cb_name, mi });
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

// ---- Std450 → GLSL function name mapping ----
fn std450ToGlsl(val: u32) ?[]const u8 {
    return switch (val) {
        1 => "round",
        2 => "roundEven",
        3 => "trunc",
        4, 5 => "abs",
        6, 7 => "sign",
        8 => "floor",
        9 => "ceil",
        10 => "fract",
        11 => "radians",
        12 => "degrees",
        13 => "sin",
        14 => "cos",
        15 => "tan",
        16 => "asin",
        17 => "acos",
        18 => "atan",
        19 => "sinh",
        20 => "cosh",
        21 => "tanh",
        22 => "asinh",
        23 => "acosh",
        24 => "atanh",
        25 => "atan",
        26 => "pow",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "inversesqrt",
        33 => "determinant",
        34 => "inverse",
        36 => "modf",
        // GLSL.std.450 spec order: FMin(37) UMin(38) SMin(39) FMax(40) UMax(41) SMax(42).
        37 => "min",
        38 => "min",
        39 => "min",
        40 => "max",
        41 => "max",
        42 => "max",
        43 => "clamp",
        44 => "clamp",
        45 => "clamp",
        46 => "mix",
        48 => "step",
        49 => "smoothstep",
        50 => "fma",
        52 => "frexp",
        53 => "ldexp",
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceforward",
        71 => "reflect",
        72 => "refract",
        73 => "findLSB",
        74 => "findMSB",
        75 => "findMSB",
        35 => "modf",
        51 => "frexp",
        76 => "interpolateAtCentroid",
        77 => "interpolateAtSample",
        78 => "interpolateAtOffset",
        54 => "packSnorm4x8",
        55 => "packUnorm4x8",
        56 => "packSnorm2x16",
        57 => "packUnorm2x16",
        58 => "packHalf2x16",
        60 => "unpackSnorm2x16",
        61 => "unpackUnorm2x16",
        62 => "unpackHalf2x16",
        63 => "unpackSnorm4x8",
        64 => "unpackUnorm4x8",
        79 => "min",
        80 => "max",
        81 => "clamp",
        else => null,
    };
}

// ---- Function emission (GLSL dialect) ----
// Part 2 of spirv_to_glsl.zig — emit functions
// This content gets appended to the main file.

/// Emit stage in/out varying declarations and mutable Private globals at file scope,
/// BEFORE any function body. A helper function may reference a stage input (e.g.
/// `uv`) or a mutable global, so these must be declared ahead of ALL functions — the
/// entry point (main) is emitted last, so declaring them there left helpers using
/// undeclared identifiers. Built-ins (gl_FragCoord, gl_Position, …) are predefined
/// and never declared here.
/// Per-member interpolation qualifier for a stage IO interface block, read from
/// `OpMemberDecorate` (Flat/Centroid/NoPerspective/Sample on `<struct, member>`).
/// Variable-level `glslInterpQual` reads `OpDecorate` (the `decs` map), which does
/// not cover per-member qualifiers — a block member `flat int h` needs `flat`
/// emitted on the member, not (only) the instance. Mirrors `glslInterpQual`'s
/// centroid/sample composition.
fn glslMemberInterpQual(m: *const ParsedModule, struct_id: u32, member_idx: u32) []const u8 {
    var aux: []const u8 = "";
    var has_flat = false;
    var has_nopersp = false;
    for (m.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 4) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
        switch (dec) {
            .flat => has_flat = true,
            .no_perspective => has_nopersp = true,
            .sample => aux = "sample ",
            .centroid => if (aux.len == 0) {
                aux = "centroid ";
            },
            else => {},
        }
    }
    if (has_flat) {
        if (std.mem.eql(u8, aux, "sample ")) return "sample flat ";
        if (std.mem.eql(u8, aux, "centroid ")) return "centroid flat ";
        return "flat ";
    }
    if (has_nopersp) {
        if (std.mem.eql(u8, aux, "sample ")) return "sample noperspective ";
        if (std.mem.eql(u8, aux, "centroid ")) return "centroid noperspective ";
        return "noperspective ";
    }
    return aux;
}

/// Emit an interface block's members with per-member interpolation qualifiers
/// (the IO-block analog of `emitStructMembers`, which omits them for UBO/SSBOs).
fn emitIoBlockMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const inst = getDef(m, struct_id) orelse return;
    if (inst.op != .TypeStruct) return;
    for (inst.words[2..], 0..) |mt_id, mi| {
        const idx: u32 = @intCast(mi);
        const q: []const u8 = glslMemberInterpQual(m, struct_id, idx);
        var mbuf: [32]u8 = undefined;
        const mname = getMemberName(m, struct_id, idx, &mbuf);
        const mti = getDef(m, mt_id);
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const et = try glslType(m, mi2.words[2], names, alloc);
                const li = getDef(m, mi2.words[3]);
                const lv: u32 = if (li) |l| (if (l.words.len > 3) l.words[3] else 1) else 1;
                try w.print("    {s}{s} {s}[{d}];\n", .{ q, et, mname, lv });
                continue;
            }
        }
        const mt = try glslType(m, mt_id, names, alloc);
        try w.print("    {s}{s} {s};\n", .{ q, mt, mname });
    }
}

/// True if any member of struct `sid` carries an interpolation decoration
/// (Flat/Centroid/NoPerspective/Sample). Such per-member qualifiers cannot be
/// expressed on a plain `struct T { ... }` declaration (GLSL rejects qualifiers on
/// struct members) — only the interface-block form `in T { flat int h; } inst;`
/// carries them, so their presence forces the block form.
/// True if a value of `type_id` requires `flat` interpolation when used as a
/// stage varying: any integer (or double) scalar/vector/matrix, or a struct that
/// transitively contains one. GLSL mandates integer/double varyings be `flat`;
/// a struct-typed varying (`in S vin;`) carrying such a member is rejected by
/// glslang ("structure must be qualified as flat in") because the plain form
/// cannot apply `flat` to individual members — only the interface-block form can.
fn typeRequiresFlat(m: *const ParsedModule, type_id: u32) bool {
    const inst = getDef(m, type_id) orelse return false;
    return switch (inst.op) {
        .TypeInt => true,
        .TypeVector, .TypeMatrix => if (inst.words.len > 2) typeRequiresFlat(m, inst.words[2]) else false,
        .TypeArray => if (inst.words.len > 2) typeRequiresFlat(m, inst.words[2]) else false,
        .TypeStruct => blk: {
            for (inst.words[2..]) |mt| {
                if (typeRequiresFlat(m, mt)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// True if any (transitive) member of struct `sid` requires `flat` interpolation.
fn structHasFlatRequiredMember(m: *const ParsedModule, sid: u32) bool {
    const inst = getDef(m, sid) orelse return false;
    if (inst.op != .TypeStruct) return false;
    for (inst.words[2..]) |mt| {
        if (typeRequiresFlat(m, mt)) return true;
    }
    return false;
}

/// True if any member of struct `sid` carries an interpolation decoration
/// (Flat/Centroid/NoPerspective/Sample). Such per-member qualifiers cannot be
/// expressed on a plain `struct T { ... }` declaration (GLSL rejects qualifiers on
/// struct members) — only the interface-block form `in T { flat int h; } inst;`
/// carries them, so their presence forces the block form.
fn structHasMemberInterpQual(m: *const ParsedModule, sid: u32) bool {
    for (m.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 4) continue;
        if (inst.words[1] != sid) continue;
        const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
        switch (dec) {
            .flat, .no_perspective, .centroid, .sample => return true,
            else => {},
        }
    }
    return false;
}

/// True if struct `sid`'s name collides with instance `instance_name` — e.g. the
/// source `in VertexIn { ... } VertexIn;` where the block tag and instance share a
/// name. The struct-then-input form (`struct VertexIn {...}; in VertexIn VertexIn;`)
/// is then a redefinition (GLSL shares one identifier namespace for struct tags and
/// variables), so the block form (decoupled tag) is required instead.
fn ioNameCollides(names: *std.AutoHashMap(u32, []const u8), sid: u32, instance_name: []const u8) bool {
    const tn = names.get(sid) orelse return false;
    return std.mem.eql(u8, tn, instance_name);
}

/// Resolve the struct type behind a stage IO variable's pointer type, unwrapping
/// array layers (e.g. `in Foo foo[3];`). Returns the TypeStruct id, or null if the
/// varying is not struct-typed.
fn ioVarStructTypeId(m: *const ParsedModule, ptr_type_id: u32) ?u32 {
    const ptr = getDef(m, ptr_type_id) orelse return null;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return null;
    var pointee_id = ptr.words[3];
    var pt = getDef(m, pointee_id) orelse return null;
    while (pt.op == .TypeArray and pt.words.len > 2) {
        pointee_id = pt.words[2];
        pt = getDef(m, pointee_id) orelse return null;
    }
    if (pt.op != .TypeStruct) return null;
    return pointee_id;
}

fn emitModuleGlobals(m: *const ParsedModule, decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), names: *std.AutoHashMap(u32, []const u8), version: u32, w: anytype, alloc: std.mem.Allocator, emitted_structs: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), needs_version: *u32) !void {
    var emitted_any_io = false;
    // gl_BaseVertex / gl_BaseInstance / gl_DrawID (shader_draw_parameters) are core
    // only at #version 460; zioshade emits them at 430 by default, where they are
    // undeclared identifiers. Raise the version when any is a stage input so the
    // renamed builtin resolves. (#170)
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Input) continue;
        const bi = getDecVal(decs, inst.words[2], .built_in) orelse continue;
        if (bi == @intFromEnum(spirv.BuiltIn.base_vertex) or
            bi == @intFromEnum(spirv.BuiltIn.base_instance) or
            bi == @intFromEnum(spirv.BuiltIn.draw_index))
        {
            needs_version.* = @max(needs_version.*, 460);
            break;
        }
    }
    // The ARB-spelling draw_parameters builtins (gl_BaseVertexARB etc.) need
    // #version 450 + GL_ARB_shader_draw_parameters (the extension is written
    // against 4.50). The frontend surfaces them as plain Inputs (not BuiltIn),
    // so check by name.
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) != .Input) continue;
        const nm = names.get(inst.words[2]) orelse continue;
        if (std.mem.eql(u8, nm, "gl_BaseVertexARB") or
            std.mem.eql(u8, nm, "gl_BaseInstanceARB") or
            std.mem.eql(u8, nm, "gl_DrawIDARB"))
        {
            needs_version.* = @max(needs_version.*, 450);
            break;
        }
    }
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Input) continue;
        const ivid = inst.words[2];
        if (getDecVal(decs, ivid, .built_in) != null) continue;
        if (isBuiltinBlockVar(m, names, ivid)) continue;
        const in_name = names.get(ivid) orelse continue;
        // gl_WorkGroupSize is a predefined GLSL compute built-in, implicitly available
        // from `layout(local_size_x = …)`. Redeclaring it as an Input is doubly illegal
        // — a reserved gl_ name and an `in` qualifier at compute global scope — so skip
        // it; the body reference resolves to the implicit built-in. (The compute
        // WorkgroupSize builtin surfaces here as a synthetic Input var without a BuiltIn
        // decoration, hence the name check rather than the built_in skip above.) (#170)
        if (m.execution_model == .GLCompute and std.mem.eql(u8, in_name, "gl_WorkGroupSize")) continue;
        // gl_BaseVertexARB/gl_BaseInstanceARB/gl_DrawIDARB are the ARB-spelling
        // draw_parameters builtins (GL_ARB_shader_draw_parameters). The frontend
        // surfaces them as plain Inputs (not BuiltIn-decorated), so without this
        // they'd be declared as user varyings -- a reserved gl_ name with no
        // location, which glslang rejects. Skip the declaration; the body reference
        // resolves to the ARB builtin once the extension is emitted (#170).
        if (std.mem.eql(u8, in_name, "gl_BaseVertexARB") or
            std.mem.eql(u8, in_name, "gl_BaseInstanceARB") or
            std.mem.eql(u8, in_name, "gl_DrawIDARB")) continue;
        const drop_loc = dropVaryingLocation(version, m.execution_model, .in);
        // A struct-typed stage input is an interface block. Two emission forms,
        // chosen per variable:
        //   * struct-then-input (`struct T {...}; in T inst;`) — the default; lets
        //     the body treat the varying as a plain struct VALUE (assign it to a
        //     local, pass it, return it), which the block form forbids. Works at
        //     #version 430. Used unless it would be invalid.
        //   * interface-block form (`in Tag {[qual] type m; ...} inst;`) — needed
        //     when struct-then-input would be rejected: a name collision (block
        //     tag == instance, e.g. `VertexIn VertexIn`) or per-member
        //     interpolation qualifiers (flat/centroid — struct members cannot
        //     carry qualifiers). Requires #version 450. The body must access the
        //     varying only by member (no whole-value use); spirv-cross makes the
        //     same call. (#GLSL-corpus Issue 1)
        if (ioVarStructTypeId(m, inst.words[1])) |sid| {
            const use_block = ioNameCollides(names, sid, in_name) or structHasMemberInterpQual(m, sid) or structHasFlatRequiredMember(m, sid);
            if (use_block) {
                const type_name = names.get(sid) orelse "IOBlock";
                emitStructForwardDecls(m, names, sid, w, alloc, emitted_structs, emitted_names) catch {};
                const tag = std.fmt.allocPrint(alloc, "{s}_io", .{type_name}) catch return error.OutOfMemory;
                if (!drop_loc) if (getDecVal(decs, ivid, .location)) |l| {
                    try w.print("layout(location = {d}) in {s}\n{{\n", .{ l, tag });
                    try emitIoBlockMembers(m, names, sid, w, alloc);
                    try w.print("}} {s};\n", .{in_name});
                    needs_version.* = @max(needs_version.*, 450);
                    emitted_any_io = true;
                    continue;
                };
                try w.print("in {s}\n{{\n", .{tag});
                try emitIoBlockMembers(m, names, sid, w, alloc);
                try w.print("}} {s};\n", .{in_name});
                needs_version.* = @max(needs_version.*, 450);
                emitted_any_io = true;
                continue;
            }
            // struct-then-input: declare the struct, then fall through to the
            // generic `in Type name;` emitter below (Type is the struct name).
            emitOneStructForwardDecl(m, names, sid, w, alloc, emitted_structs, emitted_names) catch {};
        }
        const it = try glslType(m, inst.words[1], names, alloc);
        const flat_q: []const u8 = glslInterpQual(decs, ivid);
        if (!drop_loc) if (getDecVal(decs, ivid, .location)) |l| {
            try w.print("layout(location = {d}) {s}in {s} {s};\n", .{ l, flat_q, it, in_name });
            emitted_any_io = true;
            continue;
        };
        try w.print("{s}in {s} {s};\n", .{ flat_q, it, in_name });
        emitted_any_io = true;
    }
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Output) continue;
        const ovid = inst.words[2];
        if (getDecVal(decs, ovid, .built_in) != null) continue;
        if (isBuiltinBlockVar(m, names, ovid)) continue;
        const on = names.get(ovid) orelse "_out";
        const drop_loc = dropVaryingLocation(version, m.execution_model, .out);
        if (ioVarStructTypeId(m, inst.words[1])) |sid| {
            const use_block = ioNameCollides(names, sid, on) or structHasMemberInterpQual(m, sid) or structHasFlatRequiredMember(m, sid);
            if (use_block) {
                const type_name = names.get(sid) orelse "IOBlock";
                emitStructForwardDecls(m, names, sid, w, alloc, emitted_structs, emitted_names) catch {};
                const tag = std.fmt.allocPrint(alloc, "{s}_io", .{type_name}) catch return error.OutOfMemory;
                if (!drop_loc) if (getDecVal(decs, ovid, .location)) |l| {
                    if (getDecVal(decs, ovid, .index)) |idx| {
                        try w.print("layout(location = {d}, index = {d}) out {s}\n{{\n", .{ l, idx, tag });
                    } else {
                        try w.print("layout(location = {d}) out {s}\n{{\n", .{ l, tag });
                    }
                    try emitIoBlockMembers(m, names, sid, w, alloc);
                    try w.print("}} {s};\n", .{on});
                    needs_version.* = @max(needs_version.*, 450);
                    emitted_any_io = true;
                    continue;
                };
                try w.print("out {s}\n{{\n", .{tag});
                try emitIoBlockMembers(m, names, sid, w, alloc);
                try w.print("}} {s};\n", .{on});
                needs_version.* = @max(needs_version.*, 450);
                emitted_any_io = true;
                continue;
            }
            // struct-then-input: declare the struct, then fall through.
            emitOneStructForwardDecl(m, names, sid, w, alloc, emitted_structs, emitted_names) catch {};
        }
        const ot = try glslType(m, inst.words[1], names, alloc);
        const flat_q: []const u8 = glslInterpQual(decs, ovid);
        if (!drop_loc) if (getDecVal(decs, ovid, .location)) |l| {
            // Dual-source blending: two outputs share location 0, distinguished by
            // the Index decoration (index 0 = src color, index 1 = src1). Dropping
            // `index=` collides them ("overlapping use of location 0"), so emit it.
            if (getDecVal(decs, ovid, .index)) |idx| {
                try w.print("layout(location = {d}, index = {d}) {s}out {s} {s};\n", .{ l, idx, flat_q, ot, on });
            } else {
                try w.print("layout(location = {d}) {s}out {s} {s};\n", .{ l, flat_q, ot, on });
            }
            emitted_any_io = true;
            continue;
        };
        try w.print("{s}out {s} {s};\n", .{ flat_q, ot, on });
        emitted_any_io = true;
    }
    if (emitted_any_io) try w.writeAll("\n");

    // Mutable module-scope Private globals (e.g. `float val = 0.0;` written by a
    // helper). const never-written Private vars are inlined to their literal by
    // aliasConstInitializedPrivateVars and must NOT be declared; every other Private
    // var is a real global. Emit its OpVariable initializer (word 4) when present.
    var emitted_any_priv = false;
    for (m.instructions) |ginst| {
        if (ginst.op != .Variable or ginst.words.len < 4) continue;
        const gsc: spirv.StorageClass = @enumFromInt(ginst.words[3]);
        if (gsc != .Private) continue;
        if (common.constInitializedPrivateVar(m, ginst) != null) continue;
        const gvar_id = ginst.words[2];
        const gname = names.get(gvar_id) orelse continue;
        const gptr = getDef(m, ginst.words[1]) orelse continue;
        if (gptr.op != .TypePointer or gptr.words.len < 4) continue;
        const gpointee = gptr.words[3];
        // A Private global whose value type is a user struct (e.g. `Foo obj;` or
        // `Foo arr[N];`) needs the struct declared first. The common helper
        // recurses TypeArray/TypeMatrix/TypeVector -> element then emits the
        // struct, and is a no-op for scalar pointees; emitted_structs dedups
        // against structs already declared by the resource/IO paths (so this is
        // a no-op for those -- zero regression on shaders whose struct was
        // declared via another path). `try` (not catch{}): an emission error
        // must refuse loudly with this compiler's own diagnostic, not emit
        // partial GLSL for glslang to trip over.
        try emitOneStructForwardDecl(m, names, gpointee, w, alloc, emitted_structs, emitted_names);
        if (getDef(m, gpointee)) |pd| {
            if (pd.op == .TypeArray and pd.words.len > 3) {
                const et = try glslType(m, pd.words[2], names, alloc);
                const li = getDef(m, pd.words[3]);
                const lv: u32 = if (li) |l| (if (l.words.len > 3) l.words[3] else 1) else 1;
                try w.print("{s} {s}[{d}];\n", .{ et, gname, lv });
                emitted_any_priv = true;
                continue;
            }
        }
        const gt = try glslType(m, gpointee, names, alloc);
        if (ginst.words.len >= 5) {
            const init_name = exprName(m, names, ginst.words[4], alloc);
            try w.print("{s} {s} = {s};\n", .{ gt, gname, init_name });
        } else {
            try w.print("{s} {s};\n", .{ gt, gname });
        }
        emitted_any_priv = true;
    }
    if (emitted_any_priv) try w.writeAll("\n");
}

/// GLSL qualifier for a function parameter: "" for a by-value param, "out " for a
/// pointer param whose call argument is a stage Output (the shadertoy fast-path,
/// kept byte-identical), else the body classification ("inout "/"out "). Shared by
/// the prototype and definition emitters so their signatures always match.
fn paramQualifier(m: *const ParsedModule, opi: *const std.AutoHashMap(u32, std.ArrayList(usize)), func_id: u32, param_idx: usize, is_ptr: bool, alloc: std.mem.Allocator) []const u8 {
    if (!is_ptr) return "";
    if (opi.get(func_id)) |oindices| {
        for (oindices.items) |oi| {
            if (oi == param_idx) return "out ";
        }
    }
    return switch (common.classifyPointerParam(m.instructions, m.id_defs, alloc, func_id, param_idx)) {
        .out_only => "out ",
        .in_out => "inout ",
    };
}

/// Emit a GLSL forward declaration (prototype) for a function: `rt name(params);`.
/// Must match emitFunction's signature exactly (return type, param types, and the
/// `out` qualifier from `opi`) or GLSL rejects the mismatched redeclaration.
fn emitFunctionPrototype(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), func_id: u32, opi: *const std.AutoHashMap(u32, std.ArrayList(usize)), w: anytype, alloc: std.mem.Allocator) !void {
    const fi = getDef(m, func_id) orelse return;
    if (fi.op != .Function or fi.words.len < 5) return;
    const fti = getDef(m, fi.words[4]) orelse return;
    if (fti.words.len < 3) return;
    const rt = try glslTypeWithDims(m, fti.words[2], names, alloc);
    const func_name = names.get(func_id) orelse "func";
    const func_idx = if (func_id < m.id_defs.len) m.id_defs[func_id] orelse return else return;
    try w.print("{s} {s}(", .{ rt, func_name });
    var pidx: usize = 0;
    var idx = func_idx + 1;
    while (idx < m.instructions.len) : (idx += 1) {
        const inst = m.instructions[idx];
        if (inst.op == .Label) break; // params precede the first block
        if (inst.op != .FunctionParameter) continue;
        if (pidx > 0) try w.writeAll(", ");
        var itid = inst.words[1];
        var is_ptr = false;
        if (getDef(m, inst.words[1])) |pt| {
            if (pt.op == .TypePointer and pt.words.len > 3) {
                itid = pt.words[3];
                is_ptr = true;
            }
        }
        // A pointer param is a genuine out/inout param (the frontend never emits a
        // pointer for a by-value param). The opi (detectOutParams) fast-path keeps
        // the shadertoy `out fragColor` case byte-identical; every other pointer
        // param is classified from the callee body as inout (read) or out
        // (write-only). MUST match the definition site exactly or GLSL rejects the
        // redeclaration.
        const qual = paramQualifier(m, opi, func_id, pidx, is_ptr, alloc);
        const pt2 = try glslType(m, itid, names, alloc);
        // A prototype needs only parameter TYPES; omitting names avoids introducing
        // the body's SSA param name at file scope (and matches by type regardless).
        try w.writeAll(qual);
        try w.writeAll(pt2);
        pidx += 1;
    }
    try w.writeAll(");\n");
}

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
    const rt = try glslTypeWithDims(m, rtid, names, alloc);
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
    // GLSL requires the stage entry point to be named `main`. A module without an
    // OpName on the entry function (external SPIR-V: spirv-as drops symbolic names,
    // and the OpEntryPoint name string is not a name-map entry) would otherwise
    // emit the collectNames counter fallback, e.g. `void v11()`: well-formed GLSL
    // with no entry point. Pin the entry regardless of its OpName; helpers keep
    // theirs (a helper literally named `main` is renamed by the driver to avoid a
    // definition collision with the pinned entry).
    const func_name: []const u8 = if (is_entry) "main" else (names.get(func_id) orelse "func");

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

    // #414: out/inout params are recognized by their SPIR-V type ONLY (a
    // pointer FunctionParameter, the frontend's GLSL out/inout lowering). The
    // former `Variable + Store(param)` prologue heuristic misread GLSL's
    // by-value copy of an `in` param into a mutable local (`float d = p;`) as
    // an out param: `out` signature (argument value never arrives), the local
    // aliased to the param name (a redefinition glslang rejects), and a
    // self-assign of an undefined value. A by-value param can never write back
    // to the caller, so that promotion was silent-wrong by construction.

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

    // #475: Workgroup (shared) variables are MODULE-scope OpVariables; GLSL REQUIRES
    // `shared` at global scope (function-scope `shared` is a GLSL error). Emit them here,
    // before the entry signature, scanning the whole module (the old in-body scan at
    // func_idx+1 both missed module-scope vars and placed them illegally).
    if (is_entry and m.execution_model == .GLCompute) {
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                if (@as(spirv.StorageClass, @enumFromInt(inst.words[3])) == .Workgroup) {
                    const ri = inst.words[2];
                    const tn = try glslType(m, inst.words[1], names, alloc);
                    const arr = try getArraySuffix(m, inst.words[1]);
                    try w.print("shared {s} {s}{s};\n", .{ tn, names.get(ri) orelse "shared_var", arr });
                }
            }
        }
        try w.writeAll("\n");
    }

    try w.print("{s} {s}(", .{ rt, func_name });

    for (param_ids.items, 0..) |pid, i| {
        if (i > 0) try w.writeAll(", ");
        const pi = getDef(m, pid).?;
        const pn = names.get(pid) orelse "p";
        const pti = getDef(m, pi.words[1]);
        var is_ptr = false;
        var itid = pi.words[1];
        if (pti) |pt| {
            if (pt.op == .TypePointer and pt.words.len > 3) {
                itid = pt.words[3];
                is_ptr = true;
            }
        }
        // #414: only a POINTER param can be out/inout; a by-value param stays plain.
        // Must match emitFunctionPrototype exactly (same paramQualifier) or GLSL
        // rejects the redeclaration.
        const qual = paramQualifier(m, opi, func_id, i, is_ptr, alloc);
        const pt2 = try glslType(m, itid, names, alloc);
        try w.writeAll(qual);
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
                    // SPIR-V VertexIndex(42)/InstanceIndex(43) -- the builtins Vulkan-origin
                    // shaders actually use -- map to the DESKTOP GL builtins. `gl_VertexIndex`/
                    // `gl_InstanceIndex` are Vulkan-GLSL only and are undeclared identifiers
                    // under a desktop `#version` (compile error). This matches spirv-cross's
                    // default-GL lowering. (The Vulkan base-vertex/base-instance offset is not
                    // reflected by desktop gl_VertexID/gl_InstanceID; correct for base 0.) (#170)
                    .vertex_index => "gl_VertexID",
                    .instance_index => "gl_InstanceID",
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

        // OUTPUT built-in vars (gl_Position, gl_FragDepth, gl_Layer, ...) are likewise
        // predefined in GLSL; alias them by name so the body stores to the GLSL builtin
        // instead of an undeclared OpName. Without this, an HLSL-origin module that
        // names its Position output via OpName emits `_entryPointOutput_gl_Position = v;`
        // -- a use with no declaration (the declaration pass treats builtins as predefined
        // and skips them). Mirrors the input loop above. (e54.4: arbitrary SPIR-V
        // uses-without-declaration.)
        for (output_var_ids.items) |ovid| {
            // A gl_PerVertex-style interface BLOCK carries BuiltIn on its members
            // (OpMemberDecorate), not the variable. Guard explicitly to match the
            // declaration pass (emitModuleGlobals) and stay safe if a producer ever
            // puts BuiltIn on the block var itself -- without this, the instance would
            // be renamed to gl_Position and member access would break.
            if (isBuiltinBlockVar(m, names, ovid)) continue;
            const ov_name = names.get(ovid) orelse continue;
            const obuiltin = getDecVal(decs, ovid, .built_in);
            if (obuiltin) |obi| {
                const obuiltin_name: []const u8 = switch (@as(spirv.BuiltIn, @enumFromInt(obi))) {
                    .position => "gl_Position",
                    .point_size => "gl_PointSize",
                    .clip_distance => "gl_ClipDistance",
                    .cull_distance => "gl_CullDistance",
                    .frag_depth => "gl_FragDepth",
                    .layer => "gl_Layer",
                    .viewport_index => "gl_ViewportIndex",
                    // Any other BuiltIn on an OUTPUT is not one zioshade maps to a
                    // predefined GLSL name. Keeping the OpName would silently reproduce
                    // the bug this loop fixes: the declaration pass (emitModuleGlobals)
                    // skips EVERY BuiltIn-decorated Output assuming it is predefined, so
                    // an unmapped builtin would stay a use-without-declaration. Refuse
                    // loudly instead (mandate: correct output or honest error). Known
                    // GLSL-predefined-but-unmapped outputs (safe extension points):
                    //   tess_level_outer -> gl_TessLevelOuter
                    //   tess_level_inner -> gl_TessLevelInner
                    //   primitive_id -> gl_PrimitiveID
                    //   primitive_shading_rate_ext -> gl_PrimitiveShadingRateEXT
                    else => return error.CrossCompileUnsupported,
                };
                if (!std.mem.eql(u8, ov_name, obuiltin_name)) {
                    const a = alloc.dupe(u8, obuiltin_name) catch continue;
                    if (names.fetchPut(ovid, a) catch null) |old| alloc.free(old.value);
                }
            }
        }
    }

    try w.writeAll(")\n{\n");

    try emitBody(m, names, decs, func_idx, w, alloc, is_frag, output_var_id);
    try w.writeAll("}\n");
}

// #477: SWITCH-merge phi materialization (N incoming). Mirrors HLSL/MSL — declare a
// `_phi` var per phi before the switch, assign the matching incoming at each case end.
/// The block label containing the instruction at `idx` (nearest preceding
/// OpLabel). Resolves the predecessor for a switch-merge phi copy at a
/// branch-to-switch-merge: the branch's own block. Mirrors MSL's blockLabelOf.
fn blockLabelOfGLSL(m: *const ParsedModule, idx: usize) u32 {
    var j: usize = idx;
    while (true) {
        if (m.instructions[j].op == .Label and m.instructions[j].words.len > 1) return m.instructions[j].words[1];
        if (j == 0) return 0;
        j -= 1;
    }
}

// #loop-merge-phi (port of MSL's loop-merge-phi materialization; MSL is the
// reference implementation): a phi at a loop's MERGE block selects between the
// values arriving from each exit path (the normal exit + every break). Aliasing
// it to a single incoming (the generic OpPhi handler's fallback) silently drops
// the break path's distinct value, so the generic handler honest-errors
// (UnsupportedPhiAlias) unless some mechanism owns the phi. This is that
// mechanism: collect the DIVERGENT merge phis, declare a distinct `v<id>_lm`
// carrier above the loop, and assign the per-exit-path incoming at every site
// that leaves the loop. A non-diverging phi (all incomings equal) aliases fine
// and is skipped, exactly like MSL's collectLoopMergePhis.
fn collectLoopMergePhisGLSL(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), merge_lbl: u32, list: *std.ArrayList(Instruction), alloc: std.mem.Allocator) void {
    const midx = label_map.get(merge_lbl) orelse return;
    var pj: usize = midx + 1;
    while (pj < m.instructions.len) : (pj += 1) {
        const minst = m.instructions[pj];
        if (minst.op != .Phi) break;
        if (minst.words.len < 7) continue; // need >=2 (value,pred) pairs to diverge
        var diverges = false;
        var pi: usize = 5;
        while (pi < minst.words.len) : (pi += 2) {
            if (minst.words[pi] != minst.words[3]) {
                diverges = true;
                break;
            }
        }
        if (diverges) list.append(alloc, minst) catch {};
    }
}

/// The carrier name for a loop-merge phi, derived from the IMMUTABLE result id
/// (never from `names`, which other passes may have rewritten in between -- the
/// #559/#564 lesson). The `_lm` suffix is what tells the generic OpPhi handler
/// this phi is owned here (mirrors the `_phi` ownership suffix).
fn lmPhiVarNameGLSL(rid: u32, alloc: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(alloc, "v{d}_lm", .{rid}) catch "vlm";
}

/// Assign one loop-merge phi its incoming value for predecessor `pred_lbl`
/// (the block that branches out of the loop). If `pred_lbl` is not among the
/// phi's predecessors, emit nothing (the top-of-loop fallback covers unhandled
/// paths). Mirrors MSL's emitMergePhiCopyForPred.
fn emitLoopMergePhiCopyGLSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    phi: Instruction,
    pred_lbl: u32,
    indent: []const u8,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    var pi: usize = 3;
    while (pi + 1 < phi.words.len) : (pi += 2) {
        if (phi.words[pi + 1] == pred_lbl) {
            try w.print("{s}{s} = {s};\n", .{ indent, lmPhiVarNameGLSL(phi.words[2], alloc), exprName(m, names, phi.words[pi], alloc) });
            return;
        }
    }
}

fn collectSwitchMergePhis(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), ml: u32, list: *std.ArrayList(Instruction), alloc: std.mem.Allocator) void {
    const midx = label_map.get(ml) orelse return;
    var pj: usize = midx + 1;
    while (pj < m.instructions.len) : (pj += 1) {
        const minst = m.instructions[pj];
        if (minst.op != .Phi) break;
        list.append(alloc, minst) catch {};
    }
}
fn emitSwitchPhiDecls(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, w: anytype, alloc: std.mem.Allocator) !void {
    for (phis) |phi| {
        // #ladder-phi-hoist: pre-declared at an outer arm top.
        if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(phi.words[2])) continue;
        const t = try glslType(m, phi.words[1], names, alloc);
        const vn = names.get(phi.words[2]) orelse "pv";
        try w.print("    {s} {s}_phi;\n", .{ t, vn });
    }
}
fn emitSwitchPhiCaseCopy(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, case_label: u32, w: anytype, alloc: std.mem.Allocator) !void {
    for (phis) |phi| {
        const vn = names.get(phi.words[2]) orelse "pv";
        var pi: usize = 3;
        while (pi + 1 < phi.words.len) : (pi += 2) {
            if (phi.words[pi + 1] == case_label) {
                try w.print("        {s}_phi = {s};\n", .{ vn, exprName(m, names, phi.words[pi], alloc) });
                break;
            }
        }
    }
}
fn finalizeSwitchPhis(names: *std.AutoHashMap(u32, []const u8), phis: []const Instruction, alloc: std.mem.Allocator) void {
    for (phis) |phi| {
        const vn = names.get(phi.words[2]) orelse "pv";
        const pn = std.fmt.allocPrint(alloc, "{s}_phi", .{vn}) catch continue;
        if (names.fetchPut(phi.words[2], pn) catch null) |old| alloc.free(old.value);
    }
}

/// #switch-fallthrough: the label this case/default body ultimately OpBranches to. If it
/// is the switch merge, the case is terminal (emit `break;`); if it OpBranches to another
/// case label (SPIR-V fallthrough chain), the case falls through — omit `break;` so the
/// accumulation continues, matching spirv-cross. The old "every case → break;" assumption
/// dropped fallthrough accumulation (switch_fallthrough, maxdiff 153). Mirrors HLSL.
fn caseTerminatorTargetGLSL(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), target_label: u32) ?u32 {
    const start = label_map.get(target_label) orelse return null;
    var i = start;
    while (i < m.instructions.len) : (i += 1) {
        const op = m.instructions[i].op;
        if (op == .Branch) {
            const inst = m.instructions[i];
            return if (inst.words.len >= 2) inst.words[1] else null;
        }
        if (op == .Label and i != start) return null; // next block reached before a Branch
    }
    return null;
}

/// #switch-fallthrough: true iff `lbl` is a case/default target of the OpSwitch whose
/// words are `switch_words` (words[2]=default, words[4,6,...]=case targets). Used to
/// decide whether a case body's first OpBranch target is a REAL SPIR-V fallthrough edge
/// (branch to another case/default of THIS switch) -- only then is `break;` omitted. A
/// branch to the merge, a loop header, or a selection target is NOT a fallthrough edge:
/// the case is terminal and must `break;`. Mirrors the WGSL/HLSL backends. Ported from
/// spirv_to_wgsl.zig (isSwitchCaseTarget).
/// 32-bit selector only: targets are at words[4], words[6], ... (literal,target pairs).
/// A 64-bit selector uses 2-word literals (targets at words[5], words[9], ...) -- this
/// matches the case-label EMITTER, which also assumes 32-bit, so the two stay consistent.
fn isSwitchCaseTargetGLSL(switch_words: []const u32, lbl: u32) bool {
    if (switch_words.len >= 3 and switch_words[2] == lbl) return true; // default target
    var k: usize = 4; // words[3] = first case literal, words[4] = first case target
    while (k < switch_words.len) : (k += 2) {
        if (switch_words[k] == lbl) return true;
    }
    return false;
}

/// #ladder-phi-hoist: before walking a selection arm, declare (at the ARM TOP)
/// each merge phi whose arm-side incoming is itself a phi defined inside the
/// arm -- an else-if chain's next-level phi. Records the ids in
/// g_predeclared_arm_phis so the nested selection skips its own declaration
/// (assignments stay), making this level's arm copy read a variable declared
/// at its own scope or shallower.
/// #no-then-selection hardening: the init/copy picks index only the FIRST TWO
/// (value, pred) pairs of each merge phi. A phi with 3+ preds (a shared-merge
/// flat else-if chain) can carry the needed pred in slot 3 and would silently
/// mispick -- refuse those (the collectors truncate to two pairs).
fn noThenMergePhisAreTwoPredGLSL(
    m: *const ParsedModule,
    label_map: *const std.AutoHashMap(u32, usize),
    merge_lbl: u32,
) bool {
    const mi = label_map.get(merge_lbl) orelse return true;
    var k: usize = mi + 1;
    while (k < m.instructions.len) : (k += 1) {
        const t = m.instructions[k];
        if (t.op != .Phi) break;
        if (t.words.len > 7) return false;
    }
    return true;
}

fn hoistArmIncomingPhisGLSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    label_map: *const std.AutoHashMap(u32, usize),
    w: anytype,
    alloc: std.mem.Allocator,
    phis: []const PhiDeclGLSL,
    arm_side_vals: []const u32,
    arm_lbl: u32,
    merge_lbl: u32,
    indent: []const u8,
) !void {
    if (!g_predeclared_arm_phis_init) {
        g_predeclared_arm_phis = std.AutoHashMap(u32, void).init(alloc);
        g_predeclared_arm_phis_init = true;
    }
    const merge_idx = label_map.get(merge_lbl) orelse return;
    for (phis, arm_side_vals) |pv, av| {
        _ = pv;
        if (!armRegionHasPhiGLSL(m, label_map, .{ av, av }, arm_lbl, merge_idx)) continue;
        const pd = getDef(m, av) orelse continue;
        if (pd.op != .Phi) continue;
        const rtt = glslType(m, pd.words[1], names, alloc) catch continue;
        const vn = names.get(av) orelse continue;
        try w.print("{s}{s} {s}_phi;\n", .{ indent, rtt, vn });
        g_predeclared_arm_phis.put(av, {}) catch {};
    }
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
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .Label and inst.words.len > 1) label_map.put(inst.words[1], idx) catch {};
        }
    }

    var bc_merge = std.AutoHashMap(usize, u32).init(alloc);
    defer bc_merge.deinit();
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .SelectionMerge and inst.words.len > 1) {
                const ml = inst.words[1];
                {
                    var j = idx + 1;
                    while (j < m.instructions.len) : (j += 1) {
                        const n = m.instructions[j];
                        if (n.op == .BranchConditional) {
                            bc_merge.put(j, ml) catch {};
                            break;
                        }
                        if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break;
                        if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break;
                    }
                }
                {
                    var k = idx + 1;
                    while (k < m.instructions.len) : (k += 1) {
                        const n = m.instructions[k];
                        if (n.op == .Switch) {
                            bc_merge.put(k, ml) catch {};
                            break;
                        }
                        if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break;
                        if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break;
                    }
                }
            }
        }
    }

    // Pre-pass: identify loop-header OpPhi (loop counters) — see spirv_to_hlsl.zig.
    // The maps are exposed via file-scope state (g_*) so emitWhileLoop and emitBlock
    // can read them without threading params through emitBlock's many call sites.
    var loop_phis = std.AutoHashMap(usize, std.ArrayList(PhiInfo)).init(alloc);
    var phi_hdr = std.AutoHashMap(u32, usize).init(alloc);
    var deferred_hdr = std.AutoHashMap(usize, void).init(alloc);
    var loop_hoists = std.AutoHashMap(usize, std.ArrayList(common.HoistedPhiSrc)).init(alloc);
    var hoisted_ids = std.AutoHashMap(u32, void).init(alloc);
    defer {
        var lpit = loop_phis.valueIterator();
        while (lpit.next()) |list| list.deinit(alloc);
        loop_phis.deinit();
        phi_hdr.deinit();
        deferred_hdr.deinit();
        var lhit = loop_hoists.valueIterator();
        while (lhit.next()) |list| list.deinit(alloc);
        loop_hoists.deinit();
        hoisted_ids.deinit();
        g_loop_phis = null;
        g_phi_hdr = null;
        g_deferred_hdr = null;
        g_loop_hoists = null;
        g_hoisted_ids = null;
        g_ewl_depth = 0;
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
    // #413 second pass (after loop_phis/deferred_hdr are complete): find phi
    // update values whose defining instruction lives INSIDE the loop — they
    // are declared after the top-of-loop carry copy that reads them, and in
    // the while-body scope, so their declaration must be hoisted above the
    // loop. Scanning loops in instruction order puts a value shared by nested
    // loops with the OUTERMOST loop, whose scope covers the inner one.
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const plist = loop_phis.get(li) orelse continue;
            var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, plist.items.len) catch continue;
            for (plist.items) |pi| {
                if (pi.update_id == pi.result_id) continue; // self-carry, no copy emitted
                if (hoisted_ids.contains(pi.update_id)) continue;
                if (!common.loopPhiUpdateNeedsHoist(m.instructions, m.id_defs, &label_map, &deferred_hdr, li, pi.update_id)) continue;
                hoisted_ids.put(pi.update_id, {}) catch continue;
                hlist.append(alloc, .{ .id = pi.update_id, .type_id = pi.type_id }) catch {};
            }
            if (hlist.items.len > 0) {
                loop_hoists.put(li, hlist) catch hlist.deinit(alloc);
            } else {
                hlist.deinit(alloc);
            }
        }
    }
    // #for-loop-init: extend the hoist to values the top-of-loop CARRY reads that are
    // defined in the loop HEADER (cond) block. The carry re-emits the continue block at
    // the TOP of the while-body; a continue operand defined in the header (e.g. the
    // counter OpLoad `%x = OpLoad %counter` living in a Pattern-B cond block, present
    // when the counter is a Function var used past the loop) is emitted in the body
    // AFTER the carry, so the carry reads it out of scope. GLSL/HLSL reject that (Metal
    // tolerates it, which is why prove_opt never surfaced it). OpPhi header values are
    // pre-declared, so only NON-phi header definitions need this. Mirrors the #413
    // phi-update hoist above, generalised to continue-block operands.
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const cont_lbl = minst.words[2]; // OpLoopMerge: words[1]=merge, words[2]=continue
            const cont_idx0 = label_map.get(cont_lbl) orelse continue;
            var hlbl = li;
            while (hlbl > func_idx) : (hlbl -= 1) {
                if (m.instructions[hlbl].op == .Label) break;
            } // header block = (this Label .. the LoopMerge at li)
            var hi = hlbl + 1;
            while (hi < li) : (hi += 1) {
                // Pattern-B header instructions only: those replayed INSIDE the while-body
                // (where the carry can read them out of scope). Pattern-A header instrs are
                // emitted in-place before the LoopMerge; hoisting them would declare below
                // their in-place use. deferred_hdr holds exactly the Pattern-B header instrs.
                if (!deferred_hdr.contains(hi)) continue;
                const hinst = m.instructions[hi];
                if (hinst.op == .Phi) continue; // phis are pre-declared above the loop
                const rid = common.resultIdFromOp(hinst.op, hinst.words) orelse continue; // encoding-correct result id (don't mistake words[2] of a no-result op, e.g. OpStore, for a result)
                if (hoisted_ids.contains(rid)) continue;
                // Does the continue block reference rid? Scan from word 1: no-result ops
                // (OpStore/CopyMemory/AtomicStore) carry operands at words[1..2].
                var referenced = false;
                var ci = cont_idx0 + 1;
                while (ci < m.instructions.len) : (ci += 1) {
                    const cinst = m.instructions[ci];
                    if (cinst.op == .Label or cinst.op == .FunctionEnd or cinst.op == .Branch or cinst.op == .BranchConditional) break;
                    var wi: usize = 1;
                    while (wi < cinst.words.len) : (wi += 1) {
                        if (cinst.words[wi] == rid) {
                            referenced = true;
                            break;
                        }
                    }
                    if (referenced) break;
                }
                if (!referenced) continue;
                if (loop_hoists.getPtr(li)) |e| {
                    e.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch continue;
                } else {
                    var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, 1) catch continue;
                    hlist.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                    loop_hoists.put(li, hlist) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                }
                hoisted_ids.put(rid, {}) catch {};
            }
        }
    }
    // #post-loop-header-use: the same hoist, for Pattern-B header values read AFTER the
    // loop (port of spirv_to_msl.zig's pass, PR #569 -- MSL+HLSL fixed it, GLSL was not).
    // SPIR-V only requires a def to dominate its uses, and a loop header dominates
    // everything downstream, so a value computed in loop 1's header may be read inside
    // loop 2. C scoping does not work that way -- the Pattern-B replay puts the
    // definition inside while(true){...}, a sibling scope of loop 2, so the read is out
    // of scope (graphicsfuzz_072: exit-test operands computed in loop 1's header, read in
    // loop 2 -> "undeclared identifier"). Sound because the header always executes when
    // control reaches the loop, so the hoisted var is assigned before any post-loop read.
    // Restricted to deferred_hdr (Pattern-A header instrs are emitted in place above the
    // while, already in scope); skips the merge block's leading OpPhis (a merge phi
    // referencing the value is a phi-resolution concern, not a post-loop read that needs
    // the hoist -- GLSL resolves merge phis via incoming-aliasing, separately from this).
    {
        var li = func_idx + 1;
        while (li < m.instructions.len) : (li += 1) {
            const minst = m.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            const merge_idx = label_map.get(minst.words[1]) orelse continue;
            var hlbl = li;
            while (hlbl > func_idx) : (hlbl -= 1) {
                if (m.instructions[hlbl].op == .Label) break;
            }
            var hi = hlbl + 1;
            while (hi < li) : (hi += 1) {
                if (!deferred_hdr.contains(hi)) continue;
                const hinst = m.instructions[hi];
                if (hinst.op == .Phi) continue;
                const rid = common.resultIdFromOp(hinst.op, hinst.words) orelse continue;
                if (hoisted_ids.contains(rid)) continue;
                var ci = merge_idx;
                while (ci < m.instructions.len and (m.instructions[ci].op == .Label or m.instructions[ci].op == .Phi)) : (ci += 1) {}
                var referenced = false;
                while (ci < m.instructions.len) : (ci += 1) {
                    if (m.instructions[ci].op == .FunctionEnd) break;
                    const cw = m.instructions[ci].words;
                    var wi: usize = 1;
                    while (wi < cw.len) : (wi += 1) {
                        if (cw[wi] == rid) {
                            referenced = true;
                            break;
                        }
                    }
                    if (referenced) break;
                }
                if (!referenced) continue;
                if (loop_hoists.getPtr(li)) |e| {
                    e.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch continue;
                } else {
                    var hlist = std.ArrayList(common.HoistedPhiSrc).initCapacity(alloc, 1) catch continue;
                    hlist.append(alloc, .{ .id = rid, .type_id = hinst.words[1] }) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                    loop_hoists.put(li, hlist) catch {
                        hlist.deinit(alloc);
                        continue;
                    };
                }
                hoisted_ids.put(rid, {}) catch {};
            }
        }
    }
    g_loop_phis = &loop_phis;
    g_phi_hdr = &phi_hdr;
    g_deferred_hdr = &deferred_hdr;
    g_loop_hoists = &loop_hoists;
    g_hoisted_ids = &hoisted_ids;

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
                var phi_decls = std.ArrayList(PhiDeclGLSL).initCapacity(alloc, 4) catch unreachable;
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
                // #no-then-selection: the BC's TRUE target is its own SelectionMerge
                // (`if (!(c)) { ... }` -- the true path falls through to the join).
                // Walking tl as an arm walks the MERGE BLOCK inside the if: a merge
                // is a join, not an arm, so its content then emitted TWICE (the
                // walker also continues at the merge), and the chain's phi copies
                // landed at brace depths that read arm-scoped temps outside their
                // scope (graphicsfuzz_080's 9-level else-if ladder = undeclared
                // identifier). Mirror the no-else form, inverted: init the merge
                // phis from the TRUE-side (fall-through) incoming -- pred = this
                // BC's own block -- and guard the FALSE arm under `if (!(c))`.
                if (tl == mval and fl != null) {
                    const bc_blk = blockLabelOfGLSL(m, idx);
                    // #no-then: the init/copy picks below assume the BC's own block
                    // is among each merge phi's FIRST TWO preds. A shared-merge flat
                    // else-if chain gives phis 3+ preds and would silently pick a
                    // wrong incoming (review finding) -- refuse loudly instead.
                    if (!noThenMergePhisAreTwoPredGLSL(m, &label_map, mval)) return error.UnsupportedLadderPhiScope;
                    for (phi_decls.items) |pv| {
                        if (pv.preds[0] != bc_blk and pv.preds[1] != bc_blk) return error.UnsupportedLadderPhiScope;
                    }
                    for (phi_decls.items) |pv| {
                        // #ladder-phi-hoist: pre-declared at an outer arm top; keep
                        // the fall-through init as an assignment.
                        if (pv.preds[0] != bc_blk) {} // polarity handled below
                        var tv: u32 = pv.vals[0];
                        var fv: u32 = pv.vals[1];
                        if (pv.preds[0] != bc_blk) {
                            tv = pv.vals[1];
                            fv = pv.vals[0];
                        }
                        const tvn = exprName(m, names, tv, alloc);
                        const vn_x = names.get(pv.result_id) orelse "pv";
                        if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                            try w.print("    {s}_phi = {s};\n", .{ vn_x, tvn });
                            continue;
                        }
                        const rtt = try glslType(m, pv.type_id, names, alloc);
                        try w.print("    {s} {s}_phi = {s};\n", .{ rtt, vn_x, tvn });
                    }
                    try w.print("    if (!({s}))\n    {{\n", .{cn});
                    // #ladder-phi-hoist (review finding): the no-then path lacked
                    // BOTH the hoist and the scope guard for its arm-side incoming --
                    // a chain phi two levels inside the arm read out of scope. Hoist
                    // the arm-side values (pred != the BC's own block) like emitBlock.
                    {
                        var fsides = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                        defer fsides.deinit(alloc);
                        for (phi_decls.items) |pv| {
                            var fv: u32 = pv.vals[1];
                            if (pv.preds[1] == bc_blk) fv = pv.vals[0];
                            fsides.append(alloc, fv) catch {};
                        }
                        try hoistArmIncomingPhisGLSL(m, names, &label_map, w, alloc, phi_decls.items, fsides.items, fl.?, mval, "    ");
                    }
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", false);
                    for (phi_decls.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const bc_blk2 = blockLabelOfGLSL(m, idx);
                        var fv: u32 = pv.vals[1];
                        if (pv.preds[1] != bc_blk2) fv = pv.vals[0];
                        const fvn = exprName(m, names, fv, alloc);
                        try w.print("        {s}_phi = {s};\n", .{ vn, fvn });
                    }
                    try w.writeAll("    }\n");
                    for (phi_decls.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                        if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                    }
                    if (label_map.get(mval)) |mi| {
                        idx = mi;
                    }
                    continue;
                }
                for (phi_decls.items) |pv| {
                    // #ladder-phi-hoist: an outer level pre-declared this phi at
                    // its arm top; re-declaring here would shadow it. A skipped
                    // decl that carried the no-else fall-through INIT must keep
                    // the assignment (dropping it left the phi unassigned on the
                    // condition-false path -- the hoist review finding).
                    if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                        if (!he) {
                            const fvv = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            const fvn0 = exprName(m, names, fvv, alloc);
                            const vn0 = names.get(pv.result_id) orelse "pv";
                            try w.print("    {s}_phi = {s};\n", .{ vn0, fvn0 });
                        }
                        continue;
                    }
                    const rtt = try glslType(m, pv.type_id, names, alloc);
                    const vn = names.get(pv.result_id) orelse "pv";
                    if (he) {
                        // Both arms assign it; declare uninitialized.
                        try w.print("    {s} {s}_phi;\n", .{ rtt, vn });
                    } else {
                        // No else arm (short-circuit a && b): the fall-through value is the
                        // incoming from the header block (in scope before the if); initialize
                        // to it so the phi is defined when the condition is false. Mirrors MSL.
                        const false_val = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                        // #ladder-phi-scope: an init emitted at the selection level that
                        // reads a phi defined INSIDE the true arm = undeclared identifier
                        // (graphicsfuzz_080's post-loop else-if chain).
                        if (armRegionHasPhiGLSL(m, &label_map, .{ false_val, false_val }, tl, merge_idx)) return error.UnsupportedLadderPhiScope;
                        const fvn = exprName(m, names, false_val, alloc);
                        try w.print("    {s} {s}_phi = {s};\n", .{ rtt, vn, fvn });
                    }
                }
                try w.print("    if ({s})\n    {{\n", .{cn});
                // #ladder-phi-hoist: declare any arm-side incoming that is itself
                // an arm-internal phi at the ARM TOP (before the nested braces).
                {
                    var tsides = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                    defer tsides.deinit(alloc);
                    for (phi_decls.items) |pv| {
                        const tv = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                        tsides.append(alloc, tv) catch {};
                    }
                    if (tl != mval) try hoistArmIncomingPhisGLSL(m, names, &label_map, w, alloc, phi_decls.items, tsides.items, tl, mval, "    ");
                }
                idx = try emitBlock(m, names, decs, tl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", false);
                // After true branch: assign Phi vars
                for (phi_decls.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const true_val = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                    const tvn = exprName(m, names, true_val, alloc);
                    try w.print("        {s}_phi = {s};\n", .{ vn, tvn });
                }
                if (he) {
                    try w.writeAll("    } else {\n");
                    {
                        var fsides = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                        defer fsides.deinit(alloc);
                        for (phi_decls.items) |pv| {
                            const fv = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            fsides.append(alloc, fv) catch {};
                        }
                        try hoistArmIncomingPhisGLSL(m, names, &label_map, w, alloc, phi_decls.items, fsides.items, fl.?, mval, "    ");
                    }
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ", false);
                    // After false branch: assign Phi vars
                    for (phi_decls.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const false_val = if (phiPred1InTrueRegion(m, &label_map, tl, mval, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
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
                if (label_map.get(mval)) |mi| {
                    idx = mi;
                }
            } else {
                // No OpSelectionMerge on an OpBranchConditional = unstructured
                // control flow. The previous convergence-guessing if/else
                // reconstruction was a heuristic that can silently mis-nest or
                // drop branches (same lossy class as the switch path). zioshade's
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
                // #477: materialize switch-merge phis (N incoming) as `_phi` vars.
                var sphis: std.ArrayList(Instruction) = .empty;
                defer sphis.deinit(alloc);
                collectSwitchMergePhis(m, &label_map, mval, &sphis, alloc);
                try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                const saved_switch_ctx = g_switch_ctx_glsl;
                g_switch_ctx_glsl = .{ .merge_label = mval, .phis = sphis.items };
                defer g_switch_ctx_glsl = saved_switch_ctx;
                try w.print("    switch ({s}) {{\n", .{sn});
                // Emit case targets FIRST, then `default` LAST. Emitting default last lets
                // a case whose body OpBranches to the default label (SPIR-V fallthrough INTO
                // default) fall through into it, matching spirv-cross. The old order (default
                // first) made such a case fall off the end of the switch -- silent-wrong
                // (fallthrough_then_break: sel=0 returned 16 instead of 48). Mirrors HLSL.
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == mval) continue;
                    // #continue-in-switch: a case whose OpSwitch target IS the enclosing
                    // loop's continue block (the shape zioshade's frontend emits for
                    // `case N: continue;`) must emit a structured `continue;`. Walking into
                    // the continue block instead mis-follows its back-edge to the loop
                    // header. The loop counter update lives at the while-top (_loopfirst),
                    // so a bare continue; advances it. (#584 handled a case BODY that
                    // OpBranches to the continue; this is the case TARGET being the
                    // continue.)
                    if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == target) {
                        try w.print("    case {d}: {{\n", .{switchCaseLiteral(m, inst.words[1], cv)});
                        if (g_loop_merge_ctx) |lctx| try emitLatchPhiCopiesGLSL(m, names, &label_map, lctx.continue_label, target, w, alloc);
                        try w.writeAll("    continue;\n    }\n");
                        continue;
                    };
                    // #switch-case-scope: wrap each case body in its own block. C switch
                    // cases share ONE scope, so a value declared in multiple cases (common
                    // when each case runs the same logic -- zioshade names the per-case
                    // SPIR-V ids identically, e.g. `bool v193 = ...` in case 9/5/12)
                    // collides -> redefinition (graphicsfuzz_022/_037). A per-case block
                    // gives each case its own scope; spirv-cross does the same. The
                    // switch-merge phis are declared once BEFORE the switch and assigned
                    // per case inside this block, so they stay in scope after the switch.
                    try w.print("    case {d}: {{\n", .{switchCaseLiteral(m, inst.words[1], cv)});
                    // Buffered so the trailing `break;` below can be skipped when the body
                    // already left the switch on its own (#dead-case-break).
                    var cb: std.ArrayList(u8) = .empty;
                    defer cb.deinit(alloc);
                    _ = try emitBlock(m, names, decs, target, mval, &label_map, &bc_merge, compat.listWriter(&cb, alloc), alloc, is_frag, output_var_id, "    ", false);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, target, compat.listWriter(&cb, alloc), alloc);
                    try w.writeAll(cb.items);
                    // #switch-fallthrough: omit `break;` ONLY when this case body's first
                    // OpBranch target is a real case/default label of THIS OpSwitch (a
                    // SPIR-V fallthrough edge) AND is not the merge. A branch to the
                    // switch's own MERGE is always a `break` -- even when the merge is also
                    // the OpSwitch's DEFAULT target, which happens exactly when the source
                    // switch covers every case with no default (switch_func.frag: the
                    // default operand IS the merge, so matching the default operand here
                    // misread every case's break as a fallthrough edge and dropped it --
                    // the cases then cascaded into each other, silent-wrong). Mirrors WGSL's
                    // `tt != merge_label` guard. The old `t == mval`-only test had the
                    // inverse bug (a loop-header/selection branch read as fallthrough;
                    // loop_in_case: sel=0 returned 100 instead of 3).
                    const cterm = caseTerminatorTargetGLSL(m, &label_map, target);
                    const fallthrough = if (cterm) |t| (t != mval and isSwitchCaseTargetGLSL(inst.words, t)) else false;
                    try w.writeAll(if (!fallthrough and !caseBodyTerminates(cb.items)) "    break;\n" else "");
                    try w.writeAll("    }\n");
                }
                if (dl != mval) {
                    try w.writeAll("    default: {\n");
                    var db: std.ArrayList(u8) = .empty;
                    defer db.deinit(alloc);
                    _ = try emitBlock(m, names, decs, dl, mval, &label_map, &bc_merge, compat.listWriter(&db, alloc), alloc, is_frag, output_var_id, "    ", false);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, compat.listWriter(&db, alloc), alloc);
                    try w.writeAll(db.items);
                    if (!caseBodyTerminates(db.items)) try w.writeAll("    break;\n");
                    try w.writeAll("    }\n");
                }
                try w.writeAll("    }\n");
                finalizeSwitchPhis(names, sphis.items, alloc);
                if (label_map.get(mval)) |mi| {
                    idx = mi;
                }
            } else {
                // No OpSelectionMerge on an OpSwitch = unstructured control flow
                // (e.g. externally-optimized / hand-authored SPIR-V; zioshade's own
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

// #selfloop: lower a self-loop whose continue target IS its own header (the body
// sits in the header before the LoopMerge; back-edge is the BranchConditional that
// follows it). The generic body emitter re-enters the header's own LoopMerge
// (self-recursion -> the g_ewl_depth guard -> CrossCompileUnsupported), and a bare
// recursion-guard break is silent-wrong (double body + counter reset -> infinite
// loop). Mirror spirv-cross instead: hoist the loop-carried phi inits ABOVE the loop
// (so the counter is not re-initialized each iteration), emit the straight-line
// header body ONCE, then lower the back-edge BranchConditional to
// `if (!(cond)) break; <phi back-edge updates>`. Honest-error unless the header is
// straight-line (no nested merge/switch/branch) and the back-edge's continue arm is
// its true target -- the only shape this first increment lowers; richer self-loops
// keep the prior CrossCompileUnsupported (loud, not silent-wrong). Returns the index
// of the merge block (emission continues there).
fn emitSelfLoopBodyHeaderGLSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    loop_idx: usize,
    merge_lbl: u32,
    hlbl_idx: usize,
    back_edge: Instruction,
    label_map: *const std.AutoHashMap(u32, usize),
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
) !usize {
    // The header body must be straight-line: only Phi + plain instructions up to the
    // LoopMerge (no nested LoopMerge/Switch/SelectionMerge/Branch/BranchConditional --
    // those need block-nesting-aware lowering this path does not do).
    var hi: usize = hlbl_idx + 1;
    while (hi < loop_idx) : (hi += 1) {
        switch (m.instructions[hi].op) {
            .LoopMerge, .Switch, .SelectionMerge, .Branch, .BranchConditional => return error.CrossCompileUnsupported,
            else => {},
        }
    }
    // Back-edge polarity: true target must be the header (continue), false the merge
    // (break), so the break test is `if (!(cond)) break;`. The reversed polarity is
    // equally valid but untested by the reproducer; honest-error to stay gated.
    if (back_edge.words[2] != m.instructions[hlbl_idx].words[1]) return error.CrossCompileUnsupported;

    // The loop body = the header's straight-line instructions, emitted ONCE (no
    // re-entry into the LoopMerge -> no self-recursion). Phi ops are skipped here:
    // the main emission loop already hoisted+initialized each header phi ABOVE the
    // loop (tryEmitLoopPhiDeclGLSL, reached before the LoopMerge since deferred_hdr
    // excludes phis) -- re-declaring would be a duplicate, and decl-in-loop would
    // re-zero the counter each iteration (counter-reset silent-wrong -> infinite loop).
    try w.writeAll("    while (true)\n    {\n");
    var bi: usize = hlbl_idx + 1;
    while (bi < loop_idx) : (bi += 1) {
        const inst = m.instructions[bi];
        if (inst.op == .Phi or inst.op == .Label) continue;
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
    }

    // Lower the back-edge BranchConditional (true->header=continue, false->merge=break)
    // to `if (!(cond)) break;` then the phi back-edge updates on the continue path.
    const cond_name = names.get(back_edge.words[1]) orelse "true";
    try w.print("        if (!({s})) break;\n", .{cond_name});
    if (g_loop_phis) |lp| {
        if (lp.get(loop_idx)) |plist| {
            for (plist.items) |pi| {
                if (pi.update_id == pi.result_id) continue; // self-carry, no copy
                const rname = names.get(pi.result_id) orelse continue;
                const uname = names.get(pi.update_id) orelse exprName(m, names, pi.update_id, alloc);
                try w.print("        {s} = {s};\n", .{ rname, uname });
            }
        }
    }
    try w.writeAll("    }\n");

    return label_map.get(merge_lbl) orelse (loop_idx + 2);
}

/// #latch-phi: emit the CONTINUE block's leading-phi copies for predecessor
/// `pred_lbl` (the block that branches to the continue). A continue-block phi
/// (latch phi) carries per-path values into the loop header's carry; a bare
/// `continue;` (or a silent branch-to-continue skip) left it unwritten on that
/// path -- the header carry then read a stale/uninitialized value every
/// iteration (graphicsfuzz_003: all three accumulators diverged; the TODO(latch-
/// phi) documented since #586). The phi's own name resolves via `names`; the
/// variable is declared by the carried-phi / hoist passes when the loop reads it.
/// Number of leading phis at the continue block (cheap pre-check so the fast
/// paths keep their one-line shape when there are no latch phis).
fn latchPhiCountGLSL(m: *const ParsedModule, label_map: *const std.AutoHashMap(u32, usize), cont_lbl: u32) usize {
    const cidx = label_map.get(cont_lbl) orelse return 0;
    var n: usize = 0;
    var ci: usize = cidx + 1;
    while (ci < m.instructions.len) : (ci += 1) {
        if (m.instructions[ci].op != .Phi) break;
        n += 1;
    }
    return n;
}

fn emitLatchPhiCopiesGLSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    label_map: *const std.AutoHashMap(u32, usize),
    cont_lbl: u32,
    pred_lbl: u32,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    const cidx = label_map.get(cont_lbl) orelse return;
    var ci: usize = cidx + 1;
    while (ci < m.instructions.len) : (ci += 1) {
        const phi = m.instructions[ci];
        if (phi.op != .Phi) break;
        if (phi.words.len < 5) continue;
        var pi: usize = 3;
        while (pi + 1 < phi.words.len) : (pi += 2) {
            if (phi.words[pi + 1] == pred_lbl) {
                const vn = names.get(phi.words[2]) orelse break;
                const ev = exprName(m, names, phi.words[pi], alloc);
                try w.print("        {s} = {s};\n", .{ vn, ev });
                break;
            }
        }
    }
}

// #loop-break-out-of-switch: does any OpBranch/OpBranchConditional in
// [start_idx, end_idx) target `sw_merge` (the enclosing switch's merge)? Only a
// heuristic arming decision for the flag lowering: a false negative keeps the old
// behavior (nothing regresses), a false positive costs one unused bool. Valid
// structured SPIR-V never has such a branch inside a loop region, so on the real
// corpus this is always false.
fn loopRegionBreaksToSwitchGLSL(m: *const ParsedModule, start_idx: usize, end_idx: usize, sw_merge: u32) bool {
    var i = start_idx;
    while (i < end_idx and i < m.instructions.len) : (i += 1) {
        const t = m.instructions[i];
        if (t.op == .Branch and t.words.len > 1 and t.words[1] == sw_merge) return true;
        if (t.op == .BranchConditional) {
            if (t.words.len > 2 and t.words[2] == sw_merge) return true;
            if (t.words.len > 3 and t.words[3] == sw_merge) return true;
        }
    }
    return false;
}

// #switch-arm-break + #loop-break-out-of-switch: emit, at a branch site whose
// target is the enclosing switch's merge, the switch-merge phi copy for
// predecessor block `pred_lbl`, the armed-loop flag set (when inside one), and
// the `break;`. Used by the BranchConditional arm sites in emitBlock and
// emitWhileLoop's body walker.
fn emitSwitchMergeBreakGLSL(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    sctx: SwitchCtxGLSL,
    pred_lbl: u32,
    indent: []const u8,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    try emitSwitchPhiCaseCopy(m, names, sctx.phis, pred_lbl, w, alloc);
    if (g_swbrk_flag_glsl) |f| try w.print("{s}{s} = true;\n", .{ indent, f });
    try w.print("{s}break;\n", .{indent});
}

/// #loopcond-not-exit: does the loop body (from `body_lbl` to the continue/merge
/// labels) contain ANY branch whose target is the loop merge? A no-top-test
/// while(true) needs at least one exit; structured SPIR-V guarantees the merge is
/// reachable, but verify before lowering (an exit-less emit would hang the shader).
fn loopBodyReachesMergeGLSL(
    m: *const ParsedModule,
    body_lbl: u32,
    merge_lbl: u32,
    cont_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) bool {
    const start = label_map.get(body_lbl) orelse return false;
    var i: usize = start + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) return false;
        if (inst.op == .Label and inst.words.len > 1 and (inst.words[1] == cont_lbl or inst.words[1] == merge_lbl)) return false;
        if ((inst.op == .Branch or inst.op == .BranchConditional) and inst.words.len > 1) {
            var wi: usize = if (inst.op == .Branch) 1 else 2;
            while (wi < inst.words.len) : (wi += 1) {
                if (inst.words[wi] == merge_lbl) return true;
            }
        }
    }
    return false;
}

fn armRegionHasPhiGLSL(
    m: *const ParsedModule,
    label_map: *const std.AutoHashMap(u32, usize),
    vals: [2]u32,
    arm_lbl: u32,
    mi: usize,
) bool {
    const ai = label_map.get(arm_lbl) orelse return false;
    if (ai >= mi) return false;
    for (vals) |v| {
        // phis sit at BLOCK HEADS: check the phi run after the arm label
        // and after every Label in the arm region.
        var k: usize = ai + 1;
        var at_head = true;
        while (k < mi) : (k += 1) {
            const t = m.instructions[k];
            if (at_head) {
                if (t.op == .Phi) {
                    if (t.words.len > 2 and t.words[2] == v) return true;
                    continue;
                }
                at_head = false;
            }
            if (t.op == .Label) at_head = true;
        }
    }
    return false;
}

/// #dowhile-header-carry: does the do-while BODY region (body_lbl up to the
/// continue label) contain MORE THAN ONE branch to the continue label? The
/// natural fall-through into the latch is exactly one (the last branch before
/// the latch block); any additional branch-to-cont is a source `continue;`,
/// which in pattern C would skip the bottom test (#246 hazard) -- the caller
/// then keeps its honest error.
fn doWhileBodyHasContinueGLSL(
    m: *const ParsedModule,
    body_lbl: u32,
    cont_lbl: u32,
    merge_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) bool {
    const start = label_map.get(body_lbl) orelse return true; // unknown: assume unsafe
    // #loop-merge-phi-do-while: an UNCONDITIONAL OpBranch %cont is safe only as
    // the body's LAST block (the natural fall-through immediately before the
    // latch). Track how many distinct blocks branch to cont, and whether the
    // latest one is directly followed by the cont label (no body block after).
    var cont_branch_blocks: usize = 0;
    var last_cont_branch_adjacent: bool = false;
    var reached_cont_lbl = false;
    var i: usize = start + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .Label and inst.words.len > 1 and (inst.words[1] == cont_lbl or inst.words[1] == merge_lbl)) {
            if (inst.words[1] == cont_lbl) reached_cont_lbl = true;
            break;
        }
        if (inst.op == .Label) last_cont_branch_adjacent = false;
        // A CONDITIONAL branch (BranchConditional arm / Switch case) targeting the
        // continue is a real `continue;` even when it is the ONLY cont-branch:
        // the walker emits a GLSL continue there, making the copies+bottom test
        // dead code (review #2 -- the count-based check tolerated exactly one and
        // misread a lone conditional continue as the fall-through).
        if ((inst.op == .BranchConditional or inst.op == .Switch) and inst.words.len > 1) {
            var wi: usize = 2;
            while (wi < inst.words.len) : (wi += 1) {
                if (inst.words[wi] == cont_lbl) return true;
                // An arm targeting a TRIVIAL cont block (Label + OpBranch %cont)
                // that is NOT this branch's own SelectionMerge target is also a
                // real continue: its path must skip the merge/remaining body,
                // which linear fall-through cannot express. The own-merge
                // exemption is FALSE-ARM ONLY (review finding: polarity-blind,
                // it admitted the inverted `if (c) {} else break;` whose TRUE
                // arm is the merge -- the ladder's `if (c) continue;` fast paths
                // then skipped the latch/copies/bottom test AND emitted an
                // undeclared latch temp). Only the false arm's own-merge is the
                // path the walker reaches linearly after the if (the _033/_078
                // fall-through shape); a TRUE-arm own-merge must invert the
                // guard, which the fast paths do not do. Switch cases have no
                // false arm and are never exempt.
                const arm = inst.words[wi];
                if (label_map.get(arm)) |ai| {
                    if (ai + 2 < m.instructions.len and
                        m.instructions[ai].op == .Label and
                        m.instructions[ai + 1].op == .Branch and
                        m.instructions[ai + 1].words.len > 1 and
                        m.instructions[ai + 1].words[1] == cont_lbl)
                    {
                        const is_false_arm = inst.op == .BranchConditional and wi == 3;
                        const is_own_merge = is_false_arm and i > 0 and m.instructions[i - 1].op == .SelectionMerge and
                            m.instructions[i - 1].words.len > 1 and m.instructions[i - 1].words[1] == arm;
                        if (!is_own_merge) return true;
                    }
                }
            }
        }
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == cont_lbl) {
            cont_branch_blocks += 1;
            last_cont_branch_adjacent = true;
        }
    }
    // Epilogue: the fall-through is the cont-branching block that sits directly
    // before the cont label. Anything else (a second cont-branching block, a
    // cont-branch with body blocks after it, or the scan ending at the merge
    // label / function end first) means a mid-body continue.
    if (cont_branch_blocks == 0) return false; // exits only via the bottom test / breaks
    if (cont_branch_blocks == 1 and reached_cont_lbl and last_cont_branch_adjacent) return false;
    return true;
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
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
) anyerror!usize {
    // #loop-break-on-selection-merge: expose this loop's merge label to emitBlock so a
    // side-effecting break block (`x = ...; OpBranch <loop-merge>`) emits `break;`
    // instead of silently dropping it (mandelbrot-loop: loop always ran all iters).
    // Saved/restored for nested loops (recursive emitBlock -> emitWhileLoop).
    // Bound the emitWhileLoop self-recursion (nested-loop re-entry, line ~3978). On some
    // valid-but-pathological loop structures (e.g. a self-referential LoopMerge the body
    // re-enters) the recursion does not advance and exhausts the stack -> SIGSEGV, a
    // silent mandate violation. Refuse loudly instead. Real shaders nest loops far below
    // this (GraphicsFuzz/real apps < 100); the bound is a safety net, not a capability
    // limit. The crash itself is fixed; a proper loop-lowering fix (compile these
    // shaders correctly rather than honest-error) is a separate follow-up.
    g_ewl_depth += 1;
    defer g_ewl_depth -= 1;
    if (g_ewl_depth > max_emit_while_depth) return error.CrossCompileUnsupported;
    const saved_lmc = g_loop_merge_ctx;
    g_loop_merge_ctx = .{ .merge_label = merge_lbl, .continue_label = cont_lbl };
    defer g_loop_merge_ctx = saved_lmc;
    // #loop-break-out-of-switch: saved/restored for nesting; armed (and the bool
    // declared above the loop) just before the loop opens, once is_do_while is
    // known. See g_swbrk_flag_glsl.
    var swbrk: ?[]const u8 = null;
    const saved_swbrk = g_swbrk_flag_glsl;
    defer g_swbrk_flag_glsl = saved_swbrk;
    // #413: declare loop-carried phi update temps ABOVE the loop. The top-of-
    // loop carry copy (#237) reads them on every iteration after the first;
    // without the hoist the declaration sits later in the body (and in the
    // while-body scope), so the copy read an undeclared identifier. Emitted
    // before the early-out paths below because the defining instructions
    // strip their declaration unconditionally once an id is in the hoist set.
    if (g_loop_hoists) |lh| {
        if (lh.get(loop_idx)) |hlist| {
            for (hlist.items) |h| {
                if (names.get(h.id) == null) {
                    const nm = std.fmt.allocPrint(alloc, "v{d}", .{h.id}) catch "vhoist";
                    if (names.fetchPut(h.id, nm) catch null) |old| alloc.free(old.value);
                }
                const tyname = try glslType(m, h.type_id, names, alloc);
                try w.print("    {s} {s};\n", .{ tyname, names.get(h.id) orelse "vhoist" });
            }
        }
    }

    // Two patterns after LoopMerge:
    // Pattern A: LoopMerge; Branch cond_label; ...; BranchConditional cond, body, merge
    // Pattern B: LoopMerge; BranchConditional cond, body, merge (merged condition)

    var bc_idx: usize = loop_idx + 1;
    var cond_start: ?usize = null; // start of condition instructions (Pattern A only)
    var cond_end: usize = loop_idx + 1;
    var is_do_while = false; // pattern C: condition tested at the back-edge (do-while)
    var dw_loop_when_true = true;
    // #shortcircuit-loop-cond: the loop's top test is a short-circuit chain lowered
    // structurally (while(true) + guarded break at the chain's final branch; port of
    // the MSL #622 lowering). The body walk then starts at the chain head.
    var no_top_test = false;
    var sc_chain_head: u32 = 0;

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
    // #selfloop: OpLoopMerge %merge %hdr where the continue target IS the loop
    // header (the body sits in the header before the LoopMerge). The generic body
    // emitter would re-enter the header's own LoopMerge (self-recursion -> the
    // g_ewl_depth guard -> CrossCompileUnsupported). Lower it directly instead,
    // mirroring spirv-cross. (Pattern B only: back-edge BranchConditional; a
    // Pattern-A self-loop keeps the existing honest-error.)
    if (cont_lbl == header_lbl and next_inst.op == .BranchConditional and next_inst.words.len >= 4) {
        return try emitSelfLoopBodyHeaderGLSL(m, names, decs, loop_idx, merge_lbl, hlbl_idx, next_inst, label_map, w, alloc, is_frag, ovid);
    }
    if (next_inst.op == .Branch and next_inst.words.len >= 2) {
        // FIRST: is this a do-while (bottom-test) loop? Inspect the CONTINUE block's
        // terminator BEFORE scanning the body. Otherwise the body's own `if`
        // BranchConditional (`if(x) continue;`) is mis-grabbed as the loop condition,
        // which crashes (GLSL stack-overflow) / silently miscompiles (HLSL/MSL) — #244.
        if (common.detectDoWhileBackEdge(m, cont_lbl, header_lbl, merge_lbl, label_map)) |dw_bc| {
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
                if (scan.op == .Branch or scan.op == .FunctionEnd or scan.op == .Label) {
                    bc_idx = m.instructions.len;
                    break;
                }
            }
            if (bc_idx >= m.instructions.len) {
                // #dowhile-compound-cond: a do-while whose continue block has a nested
                // OpSelectionMerge (a short-circuit && / || loop condition) reaches here:
                // detectDoWhileBackEdge returned null (the continue is not a single-block
                // back-edge) and Pattern A found no top-test condition. Previously this
                // silently DROPPED the entire loop. Honest-error instead. (Single-level short-circuit
                // is now lowered end-to-end: detectDoWhileBackEdge follows the nested SelectionMerge
                // to the real back-edge and tryInlineDoWhileCond rebuilds the OpPhi-of-bools cond;
                // this floor is reached only when detectDoWhileBackEdge STILL returns null -- shapes
                // its single-level SelectionMerge descent cannot handle. #77)
                if (label_map.get(cont_lbl)) |cidx| {
                    var sci: usize = cidx + 1;
                    while (sci < m.instructions.len) : (sci += 1) {
                        const t = m.instructions[sci];
                        if (t.op == .SelectionMerge) return error.UnsupportedDoWhileCompoundCond;
                        if (t.op == .Label or t.op == .FunctionEnd or t.op == .Branch) break;
                    }
                }
                if (label_map.get(merge_lbl)) |mi| return mi;
                return loop_idx + 1;
            }
            cond_end = bc_idx;
            // #loopcond-not-exit / #shortcircuit-loop-cond (port of the MSL #622
            // detection GLSL never had): the BranchConditional found in the "condition
            // block" is only the loop's top test if one of its targets IS the loop
            // merge. When neither is, the block is the first link of a SHORT-CIRCUIT
            // chain (`while (a && b)`) whose real exit test lives further down. Taking
            // it as the top test emits `if (!(a)) break;`, silently DROPPING every
            // later operand (graphicsfuzz_001: the `&&` collapsed to its first
            // operand -- confirmed GLSL miscompile before the phi-net refusal). If the
            // chain verifies, lower it structurally (no_top_test); otherwise refuse.
            {
                const sbc = m.instructions[bc_idx];
                if (sbc.words.len >= 4 and sbc.words[2] != merge_lbl and sbc.words[3] != merge_lbl and
                    bc_idx > 0 and m.instructions[bc_idx - 1].op == .SelectionMerge and m.instructions[bc_idx - 1].words.len > 1)
                {
                    // The selection's merge block starting with a BOOL OpPhi is what
                    // makes this a SHORT-CIRCUIT chain rather than an ordinary `if` in
                    // the first body block (the do{if(c)break;}while(false) idiom's
                    // merge carries no bool phi).
                    var is_chain = false;
                    if (label_map.get(m.instructions[bc_idx - 1].words[1])) |smi| {
                        if (smi + 1 < m.instructions.len) {
                            const sphi = m.instructions[smi + 1];
                            if (sphi.op == .Phi and sphi.words.len > 1) {
                                if (getDef(m, sphi.words[1])) |td| {
                                    if (td.op == .TypeBool) is_chain = true;
                                }
                            }
                        }
                    }
                    if (is_chain) {
                        if (common.shortCircuitChainReachesMerge(m, cond_lbl, merge_lbl, label_map)) {
                            no_top_test = true;
                            sc_chain_head = cond_lbl;
                        } else return error.UnsupportedShortCircuitLoopCond;
                    } else {
                        // #loopcond-not-exit (general form): a cond-block BranchConditional
                        // whose targets are NEITHER the loop merge is NOT the loop's exit
                        // test at all -- it is the FIRST STATEMENT of the body (a
                        // selection whose arms break deeper, e.g. graphicsfuzz_017's
                        // `if (y < 30) { color = ...; break; } else { ... }` loop). Taking
                        // it as the top test INVERTS the loop (emit `if (!(y<30)) break;`
                        // -- the y<30 arm never ran, the y>=30 arm exited early;
                        // whole-frame divergence). Lower as no-top-test: the body walk
                        // starts at the cond block, the selection lowers through the
                        // normal machinery, and branches to the loop merge inside the
                        // body are the exits (emitBlock's #loop-break-on-selection-merge
                        // + the walker's no_top_test break rules). Verify the body
                        // actually reaches the merge, else the loop would be exit-less.
                        if (loopBodyReachesMergeGLSL(m, cond_lbl, merge_lbl, cont_lbl, label_map) and !common.continueRegionHasExit(m, cont_lbl, merge_lbl, label_map)) {
                            no_top_test = true;
                            sc_chain_head = cond_lbl;
                        } else return error.UnsupportedLoopCondBlock;
                    }
                }
            }
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
    // #shortcircuit-loop-cond: the body walk starts at the CHAIN HEAD; the walker
    // lowers each link as an ordinary selection (bool phi materialized per arm) and
    // the chain's final branch to the merge as the guarded break.
    if (no_top_test) body_lbl = sc_chain_head;

    // #246: do-while emission.
    //  - STRAIGHT-LINE body  → keep the existing `while(true){ body; if(!cond)break; }`.
    //  - body WITH control flow (if/continue/break) → emit a NATIVE `do { body }
    //    while(<inlined cond>);`, IF the back-edge condition can be rebuilt as an inline
    //    expression over persistent vars (so a body `continue` re-evaluates it at the
    //    bottom test, and the controlling expression — which is outside the body block
    //    scope — references no body-local temp). Otherwise honest-error as before.
    var body_has_cf = false;
    var body_nested = false; // #dowhile-nested-body: nested loop/switch -> native do-while
    var dw_inlined: ?[]const u8 = null;
    if (is_do_while) {
        body_lbl = next_inst.words[1]; // OpBranch target = body
        dw_loop_when_true = (bc.words[2] == header_lbl);

        const bidx = label_map.get(body_lbl) orelse m.instructions.len;
        // #dowhile-nested-body: PRE-SCAN the body region (body -> continue label)
        // for a nested loop/switch BEFORE the strict trivial-body validation: the
        // strict scan rejects a branch into the nested region (a target that is
        // neither the continue nor the merge) before it could ever reach the
        // nested LoopMerge. A nested body routes to the NATIVE do-while (its body
        // emission runs through the full walker, and a body continue re-evaluates
        // the test -- pattern C skips it, fixture-proven miscompile).
        {
            var pidx = bidx + 1;
            while (pidx < m.instructions.len) : (pidx += 1) {
                const t = m.instructions[pidx];
                if (t.op == .Label and t.words.len > 1 and t.words[1] == cont_lbl) break;
                if (t.op == .FunctionEnd) break;
                if (t.op == .LoopMerge or t.op == .Switch) {
                    body_nested = true;
                    break;
                }
            }
        }
        var sidx = bidx + 1;
        while (!body_nested and sidx < m.instructions.len) : (sidx += 1) {
            const t = m.instructions[sidx];
            // The body region ends at the continue label OR the merge label (a
            // flat break exits before the latch) — the emission walker below
            // breaks on both, so the validation scan must too. Breaking on cont
            // alone walked INTO the merge block and rejected its fall-through
            // branch (#loop-merge-phi-do-while: a trivial body==cont do-while
            // whose merge continues the enclosing body).
            if (t.op == .Label and t.words.len > 1 and (t.words[1] == cont_lbl or t.words[1] == merge_lbl)) break;
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
        // #77: a compound (short-circuit && / ||) back-edge condition is an OpPhi of two
        // bools at the selection-merge block (the continue block has a nested
        // OpSelectionMerge). Rebuild it as an inline expression for BOTH straight-line
        // and control-flow-bearing bodies so the native do-while path can emit
        // `do { body } while(<cond>);`. If a phi cond cannot be rebuilt, fail LOUD:
        // the straight-line break-test path would otherwise read an unmaterialised phi
        // (silent-wrong — the hazard that kept #77 honest-errored until S1+S2 landed).
        // #dowhile-nested-body: the native path is only verified for phi-free
        // do-whiles (the _lm/latch/carry machinery was never exercised here; _027
        // emits use-before-declaration merge-phi copies under pattern C). Keep the
        // honest error when any of those phi surfaces exists.
        const cond_is_phi = if (getDef(m, bc.words[1])) |cdef| cdef.op == .Phi else false;
        // #dowhile-header-carry: a phi back-edge condition that cannot be inlined
        // (a multi-incoming if/else merge phi, not a single-block short-circuit
        // router) can still lower as PATTERN C -- provided the body has NO branch
        // to the continue label other than the natural fall-through (a mid-body
        // `continue;` would skip the bottom test; the #246 hazard). The phi cond
        // is materialized by the body machinery and read by name at the bottom.
        const dw_body_continue_free = !doWhileBodyHasContinueGLSL(m, body_lbl, cont_lbl, merge_lbl, label_map);
        if (cond_is_phi) {
            dw_inlined = common.tryInlineDoWhileCond(m, names, bc.words[1], label_map, alloc, std450ToGlsl);
            if (dw_inlined == null and !dw_body_continue_free) return error.UnsupportedDoWhileCompoundCond;
        } else if (body_has_cf or body_nested) {
            // Native do-while requires the condition rebuilt over persistent vars.
            // #dowhile-noninline-cond (deferred): a computed cond whose operand
            // chain reaches the loop HEADER phi (`%ec = %i + 1 < 4`, graphicsfuzz_027)
            // cannot be rebuilt, and pattern C is blocked until the else-if ladder
            // chain-hoist lands (graphicsfuzz_080's post-loop ladder emits an
            // arm-scoped phi read out of scope). Keep the honest error.
            dw_inlined = common.tryInlineDoWhileCond(m, names, bc.words[1], label_map, alloc, std450ToGlsl);
            if (dw_inlined == null and !dw_body_continue_free) return error.UnstructuredControlFlow;
        }
    }
    const dw_native = dw_inlined != null;

    // #dowhile-header-carry: header phis are handled by the hoist+copy machinery
    // below -- PATTERN C ONLY. The native path (do{}while(cond)) has no phi carry
    // (the #237 prologue is !is_do_while, has_phis is !is_do_while, carried_phis
    // is has_phis and !dw_native): a native do-while with header phis would
    // declare the phi above the loop and NEVER write it (silent-wrong; review
    // finding 1). So check_header = dw_native: refuse header phis exactly when
    // the native path will be taken. #loop-merge-phi-do-while: the MERGE check
    // is keyed the same way -- pattern C materializes the merge phis as
    // `v<id>_lm` carriers (declared above the loop, written per exit path), the
    // native path does not (silent-wrong risk), so it keeps the refusal. The
    // latch surface stays gated for both.
    if (body_nested and !common.dowhileNestedBodyPhiSafe(m, loop_idx, merge_lbl, cont_lbl, label_map, dw_native, dw_native)) {
        return error.UnsupportedDoWhileNestedBody;
    }

    // #237: run the SSA phi counter update at the TOP of the loop (guarded by a
    // first-iteration flag) so a `continue` — which skips the bottom-of-loop update
    // in `while(true)` — still advances the counter, matching a real `for` loop.
    var fbuf: [40]u8 = undefined;
    const first_flag = std.fmt.bufPrint(&fbuf, "_loopfirst_{d}", .{loop_idx}) catch "_loopfirst";
    // do-while loops carry their update in the body and test at the bottom; the
    // #237 top-of-loop transform does not apply.
    const has_phis = !is_do_while and (if (g_loop_phis) |lp| (if (lp.get(loop_idx)) |pl| pl.items.len > 0 else false) else false);
    // #loop-continue-deadincr (#237 generalized): emit the counter update at the TOP
    // of the loop for ALL top-test loops (!is_do_while), not just phi-counter loops.
    // A body `continue;` must advance the counter; when the increment sat at the BOTTOM
    // (old !has_phis path), `continue;` skipped it -> infinite loop (lut_palette et al.,
    // found via prove_naga on unopt SPIR-V; masked by spirv-opt -O). has_phis still
    // gates the SelectionMerge honest-error in the top walker below.
    if (!is_do_while) try w.print("    bool {s} = true;\n", .{first_flag});

    // #loop-merge-phi: collect DIVERGENT phis at the loop's merge block. Top-test
    // loops AND pattern-C do-whiles (#loop-merge-phi-do-while: the carrier's
    // normal-exit copy sits before the BOTTOM test, written from the cont-pred
    // incoming -- the top-of-loop fallback would read latch temps before their
    // single declaration, the _027 use-before-declaration hazard). The NATIVE
    // do-while never reaches here with merge phis (the gate above refuses them).
    // Also resolve the normal-exit predecessor (the smallest-index pred: the
    // header/cond block precedes every body/break block) -- top-test only; a
    // do-while's normal exit is the cont block (used directly at the bottom).
    // Port of MSL's loop_mphis machinery.
    var loop_mphis: std.ArrayList(Instruction) = .empty;
    defer loop_mphis.deinit(alloc);
    var lm_norm_pred: u32 = 0;
    if (!is_do_while) {
        collectLoopMergePhisGLSL(m, label_map, merge_lbl, &loop_mphis, alloc);
        if (loop_mphis.items.len > 0) {
            var min_idx: usize = std.math.maxInt(usize);
            var pi: usize = 3;
            while (pi + 1 < loop_mphis.items[0].words.len) : (pi += 2) {
                const pred = loop_mphis.items[0].words[pi + 1];
                if (label_map.get(pred)) |pidx| {
                    if (pidx < min_idx) {
                        min_idx = pidx;
                        lm_norm_pred = pred;
                    }
                }
            }
        }
    } else {
        collectLoopMergePhisGLSL(m, label_map, merge_lbl, &loop_mphis, alloc);
    }
    // #loop-merge-phi: declare a distinct carrier per divergent merge phi (read
    // after the loop) + rename its result id so the generic OpPhi handler does not
    // re-alias it to a single incoming (the `_lm` suffix is that handler's
    // ownership skip). Phis already owned by another mechanism (#413 hoist, a
    // loop-header phi, a materialized switch-merge phi) keep their owner:
    // re-declaring would shadow a variable that owner's assignments target
    // (the #630 shadow-redeclaration class).
    for (loop_mphis.items) |phi| {
        const owned = (if (g_hoisted_ids) |h| h.contains(phi.words[2]) else false) or
            (if (g_phi_hdr) |ph| ph.get(phi.words[2]) != null else false);
        if (owned) continue;
        if (names.get(phi.words[2])) |existing| {
            if (std.mem.endsWith(u8, existing, "_phi") or std.mem.endsWith(u8, existing, "_lm")) continue;
        }
        const t = try glslType(m, phi.words[1], names, alloc);
        const lm_name = lmPhiVarNameGLSL(phi.words[2], alloc);
        if (names.fetchPut(phi.words[2], lm_name) catch null) |old| alloc.free(old.value);
        try w.print("    {s} {s};\n", .{ t, lm_name });
    }
    // #loop-merge-phi: publish the carriers (filled above) to emitBlock's
    // break-to-loop-merge handler. Re-assigned here (same labels as the entry
    // assignment, which predates the collection) because the list must be
    // complete first (a stored .items slice would go stale on append). Pattern-C
    // do-whiles publish their carriers too (#loop-merge-phi-do-while): emitBlock's
    // break-to-loop-merge handler writes the break path's incoming, exactly as
    // for top-test loops. The native do-while reaches here only with an empty
    // list (the gate refuses merge phis on that path).
    g_loop_merge_ctx = .{ .merge_label = merge_lbl, .continue_label = cont_lbl, .merge_phis = loop_mphis.items, .pattern_c = is_do_while and !dw_native };

    // Loop-carried body phis: an OpPhi materialized inside the loop body (a
    // selection merge, e.g. `j = cond ? 40u : 30u`) whose result the CONTINUE
    // block reads (`i += int(j)`) runs a full iteration behind — the #237 hoist
    // emits the continue at the TOP, reading the PREVIOUS iteration's value. Such
    // a phi must persist ACROSS iterations, so declare it BEFORE the loop (not
    // body-local, which resets it each turn = the hoisted read gets garbage =
    // silent-wrong) and rename its result id to the `_phi` var NOW, so both the
    // hoisted read and the body's merge assignment reference the same persistent
    // variable. The common non-carried case leaves this set empty.
    var carried_phis = std.AutoHashMap(u32, void).init(alloc);
    defer carried_phis.deinit();
    if (has_phis and !dw_native) {
        var cont_refs = std.AutoHashMap(u32, void).init(alloc);
        defer cont_refs.deinit();
        if (label_map.get(cont_lbl)) |cidx| {
            var k: usize = cidx + 1;
            while (k < m.instructions.len) : (k += 1) {
                const cinst = m.instructions[k];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .BranchConditional or cinst.op == .FunctionEnd) break;
                if (cinst.words.len < 2) continue;
                for (cinst.words[1..]) |wrd| cont_refs.put(wrd, {}) catch {};
            }
        }
        if (cont_refs.count() > 0) {
            const body_start = label_map.get(body_lbl) orelse m.instructions.len;
            const body_end = label_map.get(merge_lbl) orelse m.instructions.len;
            var k: usize = if (body_start < m.instructions.len) body_start + 1 else m.instructions.len;
            while (k < body_end and k < m.instructions.len) : (k += 1) {
                const pinst = m.instructions[k];
                if (pinst.op == .FunctionEnd) break;
                if (pinst.op != .Phi or pinst.words.len < 3) continue;
                const rid = pinst.words[2];
                if (!cont_refs.contains(rid) or carried_phis.contains(rid)) continue;
                const rtt = try glslType(m, pinst.words[1], names, alloc);
                const vn = names.get(rid) orelse continue;
                const phi_name = std.fmt.allocPrint(alloc, "{s}_phi", .{vn}) catch continue;
                try w.print("    {s} {s};\n", .{ rtt, phi_name });
                if (names.fetchPut(rid, phi_name) catch null) |old| alloc.free(old.value);
                carried_phis.put(rid, {}) catch {};
            }
        }
    }

    // #loop-break-out-of-switch: arm the flag when this loop sits inside a switch
    // case AND something in its region branches straight to the switch's merge
    // (the multi-level break). do-while paths already honest-error on such
    // branches (their flat body scan rejects any OpBranch off the loop), so they
    // never arm. The post-loop guard is emitted at the loop close below.
    if (!is_do_while) {
        if (g_switch_ctx_glsl) |sctx| {
            const swm_idx = label_map.get(merge_lbl) orelse m.instructions.len;
            if (loopRegionBreaksToSwitchGLSL(m, loop_idx, swm_idx, sctx.merge_label)) {
                swbrk = std.fmt.allocPrint(alloc, "_swbrk_{d}", .{loop_idx}) catch "_swbrk";
                try w.print("    bool {s} = false;\n", .{swbrk.?});
                g_swbrk_flag_glsl = swbrk;
            }
        }
    }

    // #dowhile-header-carry: for a pattern-C do-while, declare each loop-header
    // phi ABOVE the loop from its ENTRY incoming (the body reads the persistent
    // var; without this every body reference is an undeclared identifier), and
    // remember the (result, update) pairs for the back-edge copies at the bottom.
    var dw_header_phis = std.ArrayList(struct { result_id: u32, update_id: u32 }).initCapacity(alloc, 4) catch unreachable;
    defer dw_header_phis.deinit(alloc);
    if (is_do_while and !dw_native) {
        if (g_loop_phis) |lp| {
            if (lp.get(loop_idx)) |plist| {
                for (plist.items) |pi| {
                    const pdef = getDef(m, pi.result_id) orelse continue;
                    if (pdef.op != .Phi or pdef.words.len < 7) continue;
                    // entry incoming = the pair whose pred is NOT the latch pred:
                    // with 2 incomings, the first whose pred != the phi's other pred
                    // chain... simplest: the incoming whose pred block index is
                    // BELOW the loop header (pre-loop); the back-edge pred is inside.
                    var update_val: u32 = pi.update_id;
                    {
                        const p0 = pdef.words[4];
                        const p1 = pdef.words[6];
                        const pi0 = label_map.get(p0) orelse 0;
                        const hdr_idx = label_map.get(header_lbl) orelse 0;
                        // The update is the incoming from the IN-LOOP pred (>= the
                        // header); prefer the pre-computed update_id when it is one
                        // of the phi's incomings.
                        if (pi.update_id != pdef.words[3] and pi.update_id != pdef.words[5]) {
                            if (pi0 >= hdr_idx) {
                                update_val = pdef.words[3];
                            } else {
                                update_val = pdef.words[5];
                            }
                            _ = p1;
                        }
                    }
                    // NOTE: the existing #413/loop-phi machinery already declares
                    // the header phi above the loop -- emitting our own declaration
                    // duplicates it (redefinition). Only collect the (result, update)
                    // pairs; the back-edge copies below are the missing piece.
                    dw_header_phis.append(alloc, .{ .result_id = pi.result_id, .update_id = update_val }) catch {};
                }
            }
        }
    }

    if (dw_native) {
        try w.writeAll("    do\n    {\n");
    } else {
        try w.writeAll("    while (true)\n    {\n");
    }

    if (!is_do_while) {
        // #body-is-continue double execution: when the loop's BranchConditional
        // body-target IS the continue label (single block serving as both — e.g.
        // `for (i=3; i>=0; i--) a[i] -= x;` compiles to header-cond -> cont-block ->
        // back-edge), the body walk below emits that block once per iteration. The
        // continue replay here would emit it a SECOND time — benign for pure bodies
        // (recomputation discarded) but SILENT-WRONG when the block STORES: the
        // replay re-reads post-store state and compounds the effect (each `a[i]-=x`
        // applied twice; found on graphicsfuzz_084's back-substitution loops). Emit
        // only the phi assignments in the prologue; the update temps are still in
        // scope from the previous iteration's body.
        const body_is_cont = body_lbl == cont_lbl;
        try w.print("        if (!{s})\n        {{\n", .{first_flag});
        const cont_idx0 = label_map.get(cont_lbl) orelse m.instructions.len;
        if (cont_idx0 < m.instructions.len and !body_is_cont) {
            var ci0: usize = cont_idx0 + 1;
            while (ci0 < m.instructions.len) : (ci0 += 1) {
                const cinst = m.instructions[ci0];
                if (cinst.op == .FunctionEnd or cinst.op == .Label or cinst.op == .Branch) break;
                if (cinst.op == .LoopMerge) continue;
                if (cinst.op == .SelectionMerge) {
                    // #loop-continue-deadincr: conditional increment (guarded store in an
                    // unreachable intermediate block). For !has_phis loops (newly on this
                    // top path) honest-error rather than silently drop it -> wrong counter.
                    if (!has_phis) return error.UnstructuredControlFlow;
                    continue;
                }
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
    // #shortcircuit-loop-cond: no separate condition block -- the chain is emitted by
    // the body walk (from the chain head) as nested selections, and the exit test is
    // the chain's final branch (the walker's #shortcircuit-exit rule).
    if (no_top_test) cond_start = null;
    if (cond_start) |cs| {
        if (cs < cond_end) {
            var ci: usize = cs;
            while (ci < cond_end) : (ci += 1) {
                const cinst = m.instructions[ci];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                try emitInstruction(m, names, decs, cinst, w, alloc, is_frag, ovid);
            }
        }
    } else if (!no_top_test) {
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
    if (!is_do_while and !no_top_test) {
        // #loop-merge-phi fallback: assign each carrier its NORMAL-EXIT incoming
        // every iteration. This is the value used on a normal exit, AND the safe
        // fallback for any break path not explicitly handled below (a break that
        // does not overwrite the carrier leaves the normal-exit value -- exactly
        // the old alias-to-first-incoming behavior, so no regression on
        // currently-passing loops). Handled break paths overwrite with the
        // correct break incoming. Port of MSL.
        for (loop_mphis.items) |phi| {
            try emitLoopMergePhiCopyGLSL(m, names, phi, lm_norm_pred, "        ", w, alloc);
        }
        try w.print("        if (!({s})) break;\n", .{cond_name}); // top-test only
    }
    const body_idx = label_map.get(body_lbl) orelse m.instructions.len;
    // A body==cont do-while (the degenerate trivial form: the header branches
    // straight to the latch, `do {} while (c);`) has an EMPTY body -- everything
    // between the header and the back edge belongs to the latch, emitted by the
    // cont walk below. Walking the "body" would start inside the latch and
    // re-process the back-edge BC as a body branch: its merge arm targets the
    // loop merge, which the trivial-break case reads as `if (c) break;` and the
    // header arm recurses into the loop again -- forever.
    const dw_body_empty = is_do_while and body_lbl == cont_lbl;
    if (!dw_body_empty and body_idx < m.instructions.len) {
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
                // #loopcond-not-exit: on a no-top-test loop OR a pattern-C do-while
                // (#loop-merge-phi-do-while), a walker-level OpBranch to the loop
                // merge is the loop exit -- emit the break (the arm-walker form is
                // handled by emitBlock's #loop-break-on-selection-merge). The old
                // silent skip left the loop exit-less. The break ALSO writes each
                // merge-phi carrier its incoming for THIS block, or the carrier
                // keeps a stale/undefined value on this exit path.
                if ((no_top_test or (is_do_while and !dw_native)) and binst.words.len > 1 and binst.words[1] == merge_lbl) {
                    for (loop_mphis.items) |phi| {
                        try emitLoopMergePhiCopyGLSL(m, names, phi, blockLabelOfGLSL(m, bi), "        ", w, alloc);
                    }
                    try w.writeAll("        break;\n");
                    continue;
                }
                if (binst.words.len > 1 and binst.words[1] == cont_lbl) {
                    // #latch-phi: a branch to the continue carries this block's
                    // latch-phi copies (the old skip dropped them silently).
                    try emitLatchPhiCopiesGLSL(m, names, label_map, cont_lbl, blockLabelOfGLSL(m, bi), w, alloc);
                    continue;
                }
                // #loop-break-out-of-switch: a direct OpBranch to the enclosing
                // switch's merge from the loop body's top level (the walker's old
                // generic skip DROPPED it and kept walking). Copy the switch-merge
                // phi(s) for this predecessor, set the flag, `break;` the loop --
                // the post-loop guard exits the switch. (Invalid structured input;
                // see g_swbrk_flag_glsl.)
                if (g_switch_ctx_glsl) |sctx| if (binst.words.len > 1 and sctx.merge_label == binst.words[1]) {
                    try emitSwitchMergeBreakGLSL(m, names, sctx, blockLabelOfGLSL(m, bi), "        ", w, alloc);
                    break;
                };
                if (binst.words.len > 1 and binst.words[1] == merge_lbl) continue;
                continue;
            }
            if (binst.op == .BranchConditional) {
                const ncn = names.get(binst.words[1]) orelse "c";
                const ntl = binst.words[2];
                const nfl = if (binst.words.len > 3) binst.words[3] else null;
                const nml = bc_merge.get(bi);
                // #loop-merge-phi-do-while: pattern C puts the latch/copies/bottom
                // test at the END of the while(true) body -- a GLSL `continue` jumps
                // to the TOP and skips them (the loop spins on stale carriers; the
                // graphicsfuzz_033/078 miscompile). Ladder cases that emit
                // `continue;` for the FALSE arm must degrade: the general case
                // walks the false path linearly into the latch instead. TRUE-arm
                // continue shapes cannot be expressed linearly and are refused at
                // admission (doWhileBodyHasContinueGLSL).
                const cont_emit_ok = !is_do_while or dw_native;
                // #shortcircuit-exit (GLSL port of the MSL #622 rule): on a NO-TOP-TEST
                // loop, the short-circuit chain's FINAL BranchConditional -- the one
                // whose target IS the loop merge -- is the loop's real exit test.
                // cfg_structurize synthesizes a SelectionMerge keyed to the LOOP merge
                // above it (or it has none), so the ordinary arms would walk the merge
                // block as a selection arm (post-loop code inside the loop) or skip the
                // branch entirely (an exit-less while(true)). Emit the guarded break on
                // the COMBINED condition, then keep walking into the non-breaking
                // target (the loop body follows linearly). Gated on no_top_test so
                // ordinary loops' BC handling is untouched.
                if (no_top_test and (nml == null or nml.? == merge_lbl) and
                    (ntl == merge_lbl or (nfl != null and nfl.? == merge_lbl)))
                {
                    // #loop-merge-phi: the breaking path's exit test carries this
                    // block's merge-phi copies (this BranchConditional's own block
                    // is the exiting predecessor; blockLabelOf, not a tracked
                    // current-label -- the walker jumps over Labels after nested
                    // constructs, so a tracked one would be stale). Port of MSL's
                    // #shortcircuit-exit copies.
                    for (loop_mphis.items) |phi| {
                        try emitLoopMergePhiCopyGLSL(m, names, phi, blockLabelOfGLSL(m, bi), "        ", w, alloc);
                    }
                    if (ntl == merge_lbl) {
                        try w.print("        if ({s}) break;\n", .{ncn});
                    } else {
                        try w.print("        if (!({s})) break;\n", .{ncn});
                    }
                    continue;
                }
                // #loop-break-out-of-switch: a BranchConditional arm DIRECTLY
                // targeting the enclosing switch's merge (a multi-level break).
                // Neither the trivial-break fast paths below (they compare the
                // LOOP's merge) nor the general arm walk (it re-emits the switch's
                // merge block inline, without this pred's phi copy) handles it.
                // Lower as a guarded break: the phi copy for this block, the flag
                // set, `break;` the loop -- the post-loop guard exits the switch --
                // then walk the other arm. (Invalid structured input; a valid
                // module cannot reach this branch.)
                if (g_switch_ctx_glsl) |sctx| if (ntl == sctx.merge_label or (nfl != null and nfl.? == sctx.merge_label)) {
                    const pred = blockLabelOfGLSL(m, bi);
                    if (ntl == sctx.merge_label) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        try emitSwitchMergeBreakGLSL(m, names, sctx, pred, "            ", w, alloc);
                        try w.writeAll("        }\n");
                        if (nfl != null and nfl.? != sctx.merge_label) {
                            if (nml) |om| if (om != nfl.?) {
                                _ = try emitBlock(m, names, decs, nfl.?, om, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                                if (label_map.get(om)) |omi| bi = omi;
                            };
                        }
                    } else {
                        const walked_else = blk: {
                            if (nml) |om| {
                                if (om != ntl) {
                                    try w.print("        if ({s})\n        {{\n", .{ncn});
                                    _ = try emitBlock(m, names, decs, ntl, om, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                                    try w.writeAll("        } else {\n");
                                    try emitSwitchMergeBreakGLSL(m, names, sctx, pred, "            ", w, alloc);
                                    try w.writeAll("        }\n");
                                    if (label_map.get(om)) |omi| bi = omi;
                                    break :blk true;
                                }
                            }
                            break :blk false;
                        };
                        if (!walked_else) {
                            // true arm IS the selection merge (or no merge info):
                            // guard only the break and keep walking linearly.
                            try w.print("        if (!({s}))\n        {{\n", .{ncn});
                            try emitSwitchMergeBreakGLSL(m, names, sctx, pred, "            ", w, alloc);
                            try w.writeAll("        }\n");
                        }
                    }
                    continue;
                };
                // Check if true/false labels are trivial continue/break (just a Label + Branch to cont_lbl/merge_lbl)
                const tl_is_trivial_continue = blk: {
                    if (ntl == cont_lbl) break :blk true;
                    const tli = label_map.get(ntl) orelse break :blk false;
                    if (tli + 2 < m.instructions.len and m.instructions[tli].op == .Label and m.instructions[tli + 1].op == .Branch and m.instructions[tli + 1].words.len > 1 and m.instructions[tli + 1].words[1] == cont_lbl) break :blk true;
                    break :blk false;
                };
                const fl_is_trivial_continue = blk: {
                    if (nfl == null) break :blk false;
                    if (nfl.? == cont_lbl) break :blk true;
                    const fli = label_map.get(nfl.?) orelse break :blk false;
                    if (fli + 2 < m.instructions.len and m.instructions[fli].op == .Label and m.instructions[fli + 1].op == .Branch and m.instructions[fli + 1].words.len > 1 and m.instructions[fli + 1].words[1] == cont_lbl) break :blk true;
                    break :blk false;
                };
                const tl_is_trivial_break = blk: {
                    if (ntl == merge_lbl) break :blk true;
                    const tli2 = label_map.get(ntl) orelse break :blk false;
                    if (tli2 + 2 < m.instructions.len and m.instructions[tli2].op == .Label and m.instructions[tli2 + 1].op == .Branch and m.instructions[tli2 + 1].words.len > 1 and m.instructions[tli2 + 1].words[1] == merge_lbl) break :blk true;
                    break :blk false;
                };
                const fl_is_trivial_break = blk: {
                    if (nfl == null) break :blk false;
                    if (nfl.? == merge_lbl) break :blk true;
                    const fli2 = label_map.get(nfl.?) orelse break :blk false;
                    if (fli2 + 2 < m.instructions.len and m.instructions[fli2].op == .Label and m.instructions[fli2 + 1].op == .Branch and m.instructions[fli2 + 1].words.len > 1 and m.instructions[fli2 + 1].words[1] == merge_lbl) break :blk true;
                    break :blk false;
                };
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    // #latch-phi-trivial: the trivial continue/break fast paths below
                    // emit a bare `if (c) continue;` with NO merge-phi materialization.
                    // When the selection's merge carries phis (a loop-header phi's
                    // update chain flows through here: v42 = v186_phi <- this if's
                    // phi), skipping the copies left the phi UNWRITTEN on both arms --
                    // the loop's accumulator read an uninitialized variable every
                    // iteration (graphicsfuzz_003: all three accumulators diverged in
                    // the round-trip). Route phi-bearing selections to the general
                    // case, which materializes the phis; the trivial arms then emit
                    // their continue/break through emitBlock's loop-ctx handlers.
                    const merge_has_phis = blk: {
                        const midx = label_map.get(nmv) orelse break :blk false;
                        var pj: usize = midx + 1;
                        while (pj < m.instructions.len) : (pj += 1) {
                            if (m.instructions[pj].op == .Phi) break :blk true;
                            if (m.instructions[pj].op != .Label) break;
                        }
                        break :blk false;
                    };
                    if (tl_is_trivial_continue and (fl_is_trivial_break or !nhe) and !merge_has_phis and cont_emit_ok) {
                        // if (cond) continue;  (+ the true arm's latch-phi copies)
                        const arm_lbl = if (ntl == cont_lbl) blockLabelOfGLSL(m, bi) else ntl;
                        if (latchPhiCountGLSL(m, label_map, cont_lbl) > 0) {
                            try w.print("        if ({s})\n        {{\n", .{ncn});
                            try emitLatchPhiCopiesGLSL(m, names, label_map, cont_lbl, arm_lbl, w, alloc);
                            try w.writeAll("        continue;\n        }\n");
                        } else {
                            try w.print("        if ({s}) continue;\n", .{ncn});
                        }
                    } else if (tl_is_trivial_break and fl_is_trivial_continue and !merge_has_phis and cont_emit_ok) {
                        // if (cond) break; else continue;  (+ the false arm's latch copies)
                        // #loop-merge-phi: the break carries the merge-phi copies for
                        // the breaking arm's predecessor (the trivial break block
                        // itself, or this branch's own block when the arm targets
                        // the merge directly). Port of MSL.
                        for (loop_mphis.items) |phi| {
                            const bp = if (ntl == merge_lbl) blockLabelOfGLSL(m, bi) else ntl;
                            try emitLoopMergePhiCopyGLSL(m, names, phi, bp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) break;\n", .{ncn});
                        const farm_lbl = if (nfl.? == cont_lbl) blockLabelOfGLSL(m, bi) else nfl.?;
                        if (latchPhiCountGLSL(m, label_map, cont_lbl) > 0) {
                            try w.writeAll("        {\n");
                            try emitLatchPhiCopiesGLSL(m, names, label_map, cont_lbl, farm_lbl, w, alloc);
                            try w.writeAll("        continue;\n        }\n");
                        } else {
                            try w.writeAll("        continue;\n");
                        }
                    } else if (tl_is_trivial_continue and nhe and !merge_has_phis and cont_emit_ok) {
                        // if (cond) continue; else { ... }  (+ the true arm's latch copies)
                        const tarm_lbl = if (ntl == cont_lbl) blockLabelOfGLSL(m, bi) else ntl;
                        if (latchPhiCountGLSL(m, label_map, cont_lbl) > 0) {
                            try w.print("        if ({s})\n        {{\n", .{ncn});
                            try emitLatchPhiCopiesGLSL(m, names, label_map, cont_lbl, tarm_lbl, w, alloc);
                            try w.writeAll("        continue;\n        }\n");
                        } else {
                            try w.print("        if ({s}) continue;\n", .{ncn});
                        }
                        bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                    } else if (tl_is_trivial_break) {
                        // if (cond) break;
                        // #loop-merge-phi: the break carries the merge-phi copies
                        // for the breaking arm's predecessor (as above).
                        for (loop_mphis.items) |phi| {
                            const bp = if (ntl == merge_lbl) blockLabelOfGLSL(m, bi) else ntl;
                            try emitLoopMergePhiCopyGLSL(m, names, phi, bp, "        ", w, alloc);
                        }
                        try w.print("        if ({s}) break;\n", .{ncn});
                        if (nhe) {
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        }
                    } else if (fl_is_trivial_continue and !merge_has_phis and cont_emit_ok) {
                        // if (cond) { ... } else continue;  (+ the false arm's latch copies)
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        const farm_lbl = if (nfl.? == cont_lbl) blockLabelOfGLSL(m, bi) else nfl.?;
                        if (latchPhiCountGLSL(m, label_map, cont_lbl) > 0) {
                            try w.writeAll("        }\n        {\n");
                            try emitLatchPhiCopiesGLSL(m, names, label_map, cont_lbl, farm_lbl, w, alloc);
                            try w.writeAll("        continue;\n        }\n");
                        } else {
                            try w.writeAll("        } continue;\n");
                        }
                    } else if (fl_is_trivial_break and !nhe and !merge_has_phis) {
                        // if (cond) { ... } else break; (no else = merge == false label)
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        try w.writeAll("        }\n");
                    } else if (ntl == nmv and nfl != null) {
                        // #no-then-selection (the emitBody/emitBlock ports): the BC's
                        // body_phis equivalent, collected here (the general case's list
                        // is scoped inside its own block).
                        var nt_phis = std.ArrayList(PhiDeclGLSL).initCapacity(alloc, 4) catch unreachable;
                        defer nt_phis.deinit(alloc);
                        if (label_map.get(nmv)) |midx5| {
                            var pj5: usize = midx5 + 1;
                            while (pj5 < m.instructions.len) : (pj5 += 1) {
                                const minst = m.instructions[pj5];
                                if (minst.op != .Phi) break;
                                if (names.get(minst.words[2])) |ex| {
                                    if (std.mem.endsWith(u8, ex, "_lm")) continue;
                                }
                                if (minst.words.len >= 7) {
                                    nt_phis.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
                                }
                            }
                        }
                        // (the rest of the no-then emission follows)
                        // TRUE target is its own SelectionMerge. Walking tl as an arm
                        // walks the MERGE BLOCK inside the if (its phis then hit the
                        // generic handler unowned = UnsupportedPhiAlias, and phi-free
                        // content double-emits). Emit inverted: init the merge phis
                        // from the BC-block incoming, guard the false arm under
                        // `if (!(c))`, and hoist the arm-side chain phis at the arm top.
                        const bc_blk = blockLabelOfGLSL(m, bi);
                        if (!noThenMergePhisAreTwoPredGLSL(m, label_map, nmv)) return error.UnsupportedLadderPhiScope;
                        for (nt_phis.items) |pv| {
                            if (pv.preds[0] != bc_blk and pv.preds[1] != bc_blk) return error.UnsupportedLadderPhiScope;
                        }
                        for (nt_phis.items) |pv| {
                            var tv: u32 = pv.vals[0];
                            if (pv.preds[0] != bc_blk) tv = pv.vals[1];
                            const tvn = exprName(m, names, tv, alloc);
                            const vn_x = names.get(pv.result_id) orelse "pv";
                            if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                                try w.print("        {s}_phi = {s};\n", .{ vn_x, tvn });
                                continue;
                            }
                            const rtt = try glslType(m, pv.type_id, names, alloc);
                            try w.print("        {s} {s}_phi = {s};\n", .{ rtt, vn_x, tvn });
                        }
                        try w.print("        if (!({s}))\n        {{\n", .{ncn});
                        {
                            var fsides5 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                            defer fsides5.deinit(alloc);
                            for (nt_phis.items) |pv| {
                                var fv: u32 = pv.vals[1];
                                if (pv.preds[1] == bc_blk) fv = pv.vals[0];
                                fsides5.append(alloc, fv) catch {};
                            }
                            try hoistArmIncomingPhisGLSL(m, names, label_map, w, alloc, nt_phis.items, fsides5.items, nfl.?, nmv, "        ");
                        }
                        bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        const arm_exit5 = blockLabelOfGLSL(m, bi);
                        for (nt_phis.items) |pv| {
                            const vn = names.get(pv.result_id) orelse "pv";
                            var fv: u32 = pv.vals[1];
                            if (pv.preds[1] != arm_exit5) fv = pv.vals[0];
                            const fvn = exprName(m, names, fv, alloc);
                            try w.print("            {s}_phi = {s};\n", .{ vn, fvn });
                        }
                        try w.writeAll("        }\n");
                        for (nt_phis.items) |pv| {
                            const vn = names.get(pv.result_id) orelse "pv";
                            const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                            if (names.fetchPut(pv.result_id, phi_name) catch null) |oldn| alloc.free(oldn.value);
                        }
                    } else {
                        // General case — materialize any phis at the merge (val = cond
                        // ? a : b), exactly like the top-level and emitBlock selection
                        // handlers. A loop body's if/else used to SKIP this, so a phi at
                        // the merge was dropped: its true value vanished and its result
                        // aliased to the block-scoped false value (undeclared at the use
                        // site = invalid GLSL). (phi_loop_branch)
                        var body_phis = std.ArrayList(PhiDeclGLSL).initCapacity(alloc, 4) catch unreachable;
                        defer body_phis.deinit(alloc);
                        if (label_map.get(nmv)) |midx| {
                            var pj: usize = midx + 1;
                            while (pj < m.instructions.len) : (pj += 1) {
                                const minst = m.instructions[pj];
                                if (minst.op != .Phi) break;
                                // #loop-merge-phi: a carrier renamed to `v<id>_lm` by
                                // this loop's own pre-scan is owned there (declared
                                // above the loop, assigned per exit path). This can
                                // only happen when the selection's merge IS the
                                // loop's merge; re-materializing it as a `_phi` temp
                                // would shadow the carrier the exit paths write.
                                if (names.get(minst.words[2])) |ex| {
                                    if (std.mem.endsWith(u8, ex, "_lm")) continue;
                                }
                                if (minst.words.len >= 7) {
                                    body_phis.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
                                }
                            }
                        }
                        for (body_phis.items) |pv| {
                            // #ladder-phi-hoist: pre-declared at an outer arm top; a
                            // skipped no-else init keeps its assignment (as above).
                            if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                                if (!nhe) {
                                    const fvv = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                    const fvn0 = exprName(m, names, fvv, alloc);
                                    const vn0 = names.get(pv.result_id) orelse "pv";
                                    try w.print("        {s}_phi = {s};\n", .{ vn0, fvn0 });
                                }
                                continue;
                            }
                            // A loop-carried phi was already declared at loop top (a
                            // carried_phis phi as `vN_phi`, or a #413-hoisted back-edge
                            // carrier as its base name); don't re-declare it body-local.
                            const pre_declared = carried_phis.contains(pv.result_id) or phiIsHoistedLoopCarrierGLSL(pv.result_id);
                            // A pre-declared phi must NOT be redeclared (that would shadow the
                            // variable the loop's carry copy reads), but with no else arm it
                            // still needs the fall-through assignment. Skipping the line
                            // outright left the carrier holding the PREVIOUS iteration's value
                            // whenever the condition was false -- graphicsfuzz_045 emitted
                            // `int v50;` read by `v39 = v50;` with the only write inside the
                            // `if`. Drop the type, keep the assignment. Mirrors MSL and #572.
                            if (pre_declared and nhe) continue;
                            const rtt = try glslType(m, pv.type_id, names, alloc);
                            const vn = names.get(pv.result_id) orelse "pv";
                            const sfx: []const u8 = if (pre_declared) "" else "_phi";
                            if (nhe) {
                                try w.print("        {s} {s}{s};\n", .{ rtt, vn, sfx });
                            } else {
                                // No else arm: initialize to the fall-through (header) value so
                                // the phi is defined when the condition is false. Mirrors MSL.
                                const false_val = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                // #ladder-phi-scope: the init is emitted at the SELECTION's
                                // level (outside the arm braces). A fall-through value that is
                                // itself a phi defined inside the TRUE arm reads outside its
                                // scope = undeclared identifier (graphicsfuzz_080's 5-deep
                                // else-if chain). Honest-error until the chain-hoist lands.
                                // nmv is a LABEL id; armRegionHasPhiGLSL wants the merge
                                // block's instruction INDEX (review: passing the label
                                // silently disabled this guard -- label ids never exceed
                                // the def's index, so the scan saw only a prefix).
                                if (label_map.get(nmv)) |nmv_idx| {
                                    if (armRegionHasPhiGLSL(m, label_map, .{ false_val, false_val }, ntl, nmv_idx)) return error.UnsupportedLadderPhiScope;
                                }
                                const fvn = exprName(m, names, false_val, alloc);
                                if (pre_declared) {
                                    try w.print("        {s} = {s};\n", .{ vn, fvn });
                                } else {
                                    try w.print("        {s} {s}{s} = {s};\n", .{ rtt, vn, sfx, fvn });
                                }
                            }
                        }
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        // #ladder-phi-hoist: declare arm-side incomings that are arm-internal
                        // phis at the ARM TOP.
                        if (ntl != nmv) {
                            var tsides3 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                            defer tsides3.deinit(alloc);
                            for (body_phis.items) |pv| {
                                const tv = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                                tsides3.append(alloc, tv) catch {};
                            }
                            try hoistArmIncomingPhisGLSL(m, names, label_map, w, alloc, body_phis.items, tsides3.items, ntl, nmv, "        ");
                        }
                        bi = try emitBlock(m, names, decs, ntl, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        for (body_phis.items) |pv| {
                            // A carried phi is already renamed to `vN_phi`; a #413-hoisted
                            // back-edge carrier keeps its base name. Both write the bare
                            // (current) name; others get the `_phi` suffix here.
                            const carried = carried_phis.contains(pv.result_id) or phiIsHoistedLoopCarrierGLSL(pv.result_id);
                            const vn = names.get(pv.result_id) orelse "pv";
                            const true_val = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                            const tvn = exprName(m, names, true_val, alloc);
                            if (carried) {
                                try w.print("            {s} = {s};\n", .{ vn, tvn });
                            } else {
                                try w.print("            {s}_phi = {s};\n", .{ vn, tvn });
                            }
                        }
                        if (nhe) {
                            try w.writeAll("        } else {\n");
                            {
                                var fsides3 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                                defer fsides3.deinit(alloc);
                                for (body_phis.items) |pv| {
                                    const fv = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                    fsides3.append(alloc, fv) catch {};
                                }
                                try hoistArmIncomingPhisGLSL(m, names, label_map, w, alloc, body_phis.items, fsides3.items, nfl.?, nmv, "        ");
                            }
                            bi = try emitBlock(m, names, decs, nfl.?, nmv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                            for (body_phis.items) |pv| {
                                const carried = carried_phis.contains(pv.result_id) or phiIsHoistedLoopCarrierGLSL(pv.result_id);
                                const vn = names.get(pv.result_id) orelse "pv";
                                const false_val = if (phiPred1InTrueRegion(m, label_map, ntl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                                const fvn = exprName(m, names, false_val, alloc);
                                if (carried) {
                                    try w.print("            {s} = {s};\n", .{ vn, fvn });
                                } else {
                                    try w.print("            {s}_phi = {s};\n", .{ vn, fvn });
                                }
                            }
                        }
                        try w.writeAll("        }\n");
                        for (body_phis.items) |pv| {
                            // Carried phis were renamed at the top; hoisted carriers keep
                            // their base name. Either way, don't rename again.
                            if (carried_phis.contains(pv.result_id) or phiIsHoistedLoopCarrierGLSL(pv.result_id)) continue;
                            const vn = names.get(pv.result_id) orelse "pv";
                            const phi_name = std.fmt.allocPrint(alloc, "{s}_phi", .{vn}) catch continue;
                            if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                        }
                    }
                    if (label_map.get(nmv)) |nmi| {
                        bi = nmi;
                    }
                }
                continue;
            }
            if (binst.op == .Switch) {
                if (binst.words.len < 3) continue;
                const sn = names.get(binst.words[1]) orelse "s";
                const dl = binst.words[2];
                const sml = bc_merge.get(bi);
                if (sml) |smv| {
                    // #478 F3: materialize switch-merge phis (N incoming) as `_phi` vars.
                    var sphis: std.ArrayList(Instruction) = .empty;
                    defer sphis.deinit(alloc);
                    collectSwitchMergePhis(m, label_map, smv, &sphis, alloc);
                    try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                    const saved_switch_ctx = g_switch_ctx_glsl;
                    g_switch_ctx_glsl = .{ .merge_label = smv, .phis = sphis.items };
                    defer g_switch_ctx_glsl = saved_switch_ctx;
                    try w.print("        switch ({s}) {{\n", .{sn});
                    if (dl != smv) {
                        try w.writeAll("        default: {\n");
                        bi = try emitBlock(m, names, decs, dl, smv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, w, alloc);
                        try w.writeAll("        break;\n");
                        try w.writeAll("        }\n");
                    }
                    var wi: usize = 3;
                    while (wi + 1 < binst.words.len) : (wi += 2) {
                        const cv = binst.words[wi];
                        const target = binst.words[wi + 1];
                        if (target == smv) continue;
                        // #continue-in-switch (case target IS the loop continue): see emitBody.
                        if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == target) {
                            try w.print("        case {d}: {{\n", .{switchCaseLiteral(m, binst.words[1], cv)});
                            if (g_loop_merge_ctx) |lctx| try emitLatchPhiCopiesGLSL(m, names, label_map, lctx.continue_label, target, w, alloc);
                            try w.writeAll("        continue;\n        }\n");
                            continue;
                        };
                        try w.print("        case {d}: {{\n", .{switchCaseLiteral(m, binst.words[1], cv)});
                        bi = try emitBlock(m, names, decs, target, smv, label_map, bc_merge, w, alloc, is_frag, ovid, "        ", false);
                        try emitSwitchPhiCaseCopy(m, names, sphis.items, target, w, alloc);
                        try w.writeAll("        break;\n");
                        try w.writeAll("        }\n");
                    }
                    try w.writeAll("        }\n");
                    finalizeSwitchPhis(names, sphis.items, alloc);
                    if (label_map.get(smv)) |smi| {
                        bi = smi;
                    }
                }
                continue;
            }
            try emitInstruction(m, names, decs, binst, w, alloc, is_frag, ovid);
        }
    }
    // Emit continue block (e.g., i++ in for-loops) at the BOTTOM. ALL top-test loops
    // (!is_do_while) now hoist the update to the top (#237 / #loop-continue-deadincr),
    // so this bottom walker runs only for straight-line do-while (pattern C). The
    // native do-while (#246) rebuilds its latch condition inline below.
    if (is_do_while and !dw_native) {
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
            // #loop-merge-phi-do-while: the bottom test's exit edge leaves from
            // the CONT block -- write each carrier its cont-pred incoming BEFORE
            // the test. On the fall-through path (test passes) the copy is dead:
            // the next iteration's copy or a break path's own copy overwrites it
            // before the post-loop read. Placed here (not at the loop top) so a
            // latch-temp incoming is already declared by the latch walk above.
            for (loop_mphis.items) |phi| {
                try emitLoopMergePhiCopyGLSL(m, names, phi, cont_lbl, "        ", w, alloc);
            }
            const dwc = names.get(bc.words[1]) orelse "true";
            if (dw_loop_when_true) {
                try w.print("        if (!({s})) break;\n", .{dwc});
            } else {
                try w.print("        if ({s}) break;\n", .{dwc});
            }
            // #dowhile-header-carry: pattern-C do-while back-edge copies, AFTER
            // the bottom test. The latch walk above emitted the update defs
            // (e.g. `v12 = v11 + 1;`); the copy re-assigns the persistent
            // header-phi var so the NEXT iteration reads the new value. It must
            // run only on the CONTINUE path (the back edge): a phi's value after
            // the loop is the value from the LAST HEADER ENTRY, so copying
            // before the test made a break carry the UPDATED value instead
            // (fixture dowhile_switch_noninline: post-loop read off by one
            // iteration, a 1024-pixel render DIFFER found by class 3's probe).
            // The copies before the loop-closing brace = the back edge exactly.
            for (dw_header_phis.items) |hp| {
                const rn = names.get(hp.result_id) orelse continue;
                const uv = exprName(m, names, hp.update_id, alloc);
                try w.print("        {s} = {s};\n", .{ rn, uv });
            }
        }
        try w.writeAll("    }\n");
    }
    // #loop-break-out-of-switch: the flag's post-loop guard. A set flag means a
    // break-to-switch-merge fired inside the loop: the case's remaining code must
    // be SKIPPED (it would clobber the switch-merge phi copied at the site). With
    // no enclosing armed loop the `break;` exits the switch itself; inside another
    // loop it exits ONE level and propagates the parent flag, whose own post-loop
    // guard carries it the rest of the way out.
    if (swbrk) |f| {
        if (saved_swbrk) |pf| {
            try w.print("    if ({s})\n    {{\n    {s} = true;\n    break;\n    }}\n", .{ f, pf });
        } else {
            try w.print("    if ({s})\n    {{\n    break;\n    }}\n", .{f});
        }
    }
    if (label_map.get(merge_lbl)) |mi| return mi;
    return loop_idx + 1;
}

fn emitBlock(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    label: u32,
    merge_label: u32,
    lm: *const std.AutoHashMap(u32, usize),
    bm: *const std.AutoHashMap(usize, u32),
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
    indent: []const u8,
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
            // #switch-arm-break (fall-through edge): this walker's merge_label IS
            // the switch merge when called from the switch case loop. A MULTI-BLOCK
            // case's terminal OpBranch to the merge carries the case's fall-through
            // switch-merge phi incoming — emit the per-pred copy (this block is the
            // pred) before the case's trailing break, or the merge phi keeps a stale
            // value on the fall-through path (graphicsfuzz_021: the texture sample's
            // Y coordinate read the stale phi; R matched, G/B flipped). The case
            // loop's emitSwitchPhiCaseCopy(case ENTRY label) misses multi-block
            // cases — the branch's own block is the pred, not the entry.
            if (g_switch_ctx_glsl) |sctx| if (sctx.merge_label == merge_label and !is_switch) {
                try emitSwitchPhiCaseCopy(m, names, sctx.phis, blockLabelOfGLSL(m, i), w, alloc);
            };
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
            if (is_switch) {
                const sw_br_target = if (inst.words.len > 1) inst.words[1] else 0;
                // A switch case that branches to the enclosing LOOP's continue is a
                // structured continue, not a switch break (#switch-case-continue).
                // #loop-merge-phi-do-while: for a pattern-C do-while, `continue;`
                // would skip the latch/copies/bottom test -- fall out of the case
                // instead (admission guarantees this cont-branch is the adjacent
                // final fall-through; Switch arms targeting the continue directly
                // are refused at admission).
                if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == sw_br_target) {
                    // #latch-phi: this block's continue carries its latch-phi copies.
                    try emitLatchPhiCopiesGLSL(m, names, lm, ctx.continue_label, blockLabelOfGLSL(m, i), w, alloc);
                    if (!ctx.pattern_c) {
                        try w.print("{s}    continue;\n", .{indent});
                    }
                    break;
                };
                // The #69 loop-header follow, which the switch path never had: a case body
                // that flows into a loop branches to the loop HEADER, and ending the case
                // here emitted `case 0: { break; }` with the loop and everything after it
                // gone (tests/spirv-cross/loop_in_case.frag). The branch to the switch's own
                // merge is already handled above, so this only ever follows a real loop.
                if (isLoopHeaderGLSL(m, lm, sw_br_target)) continue;
                try w.print("{s}    break;\n", .{indent});
                break;
            }
            const br_target = if (inst.words.len > 1) inst.words[1] else 0;
            // #loop-break-on-selection-merge: an OpBranch (from a side-effecting break
            // block) to the enclosing LOOP's merge is a structured break. Without this the
            // break is silently dropped (mandelbrot-loop's escape exit). Mirrors MSL.
            // #loop-merge-phi: the break ALSO assigns each merge-phi carrier its
            // incoming for THIS predecessor (the branch's own block), or the carrier
            // keeps the top-of-loop normal-exit fallback and the post-loop read
            // silently takes the wrong exit path's value.
            if (g_loop_merge_ctx) |ctx| if (ctx.merge_label == br_target) {
                const cp_indent = std.fmt.allocPrint(alloc, "{s}    ", .{indent}) catch indent;
                for (ctx.merge_phis) |phi| {
                    try emitLoopMergePhiCopyGLSL(m, names, phi, blockLabelOfGLSL(m, i), cp_indent, w, alloc);
                }
                try w.print("{s}    break;\n", .{indent});
                break;
            };
            // #switch-case-continue: an OpBranch to the enclosing LOOP's continue is a
            // structured continue. A switch case (emitted with is_switch=false) that
            // continues the outer loop would otherwise end the block here and fall through
            // to the switch handler's unconditional `break;`, so the post-switch code runs
            // on the continue path -> silent-wrong (loop-dominator-and-switch-default).
            // #loop-merge-phi-do-while: for a pattern-C do-while, `continue;` would
            // skip the latch/copies/bottom test at the END of the while(true) body --
            // fall out of the block instead (admission guarantees an arm-walked
            // OpBranch-to-cont is the adjacent final fall-through; mid-body
            // continues are refused by doWhileBodyHasContinueGLSL).
            if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == br_target) {
                // #latch-phi: this block's continue carries its latch-phi copies
                // (the most common shape: `if (c) { <compute>; continue; }` walked
                // here by emitBlock — leaving them out kept the loop-header carry
                // unwritten on the continue path, review of the first cut).
                try emitLatchPhiCopiesGLSL(m, names, lm, ctx.continue_label, blockLabelOfGLSL(m, i), w, alloc);
                if (!ctx.pattern_c) {
                    try w.print("{s}    continue;\n", .{indent});
                }
                break;
            };
            // #switch-arm-break: an OpBranch to the enclosing SWITCH's merge is a
            // `break` out of the switch from inside a selection arm. Previously the
            // walker ended here emitting NOTHING — the early-exit never fired and the
            // switch-merge phi kept its stale value on that path (silent-wrong;
            // graphicsfuzz_021's `if (c) { phi_copy; break; }`). Emit the per-edge
            // phi copy for THIS block (the branch's own block label) then `break;`.
            // Mirrors MSL's g_switch_ctx handler.
            if (g_switch_ctx_glsl) |sctx| if (sctx.merge_label == br_target) {
                try emitSwitchPhiCaseCopy(m, names, sctx.phis, blockLabelOfGLSL(m, i), w, alloc);
                // #loop-break-out-of-switch: inside an armed loop the bare
                // `break;` only exits the LOOP -- set the flag so the post-loop
                // guard skips the rest of the case (which would clobber the phi
                // copied just above) and exits the switch.
                if (g_swbrk_flag_glsl) |f| try w.print("{s}    {s} = true;\n", .{ indent, f });
                try w.print("{s}    break;\n", .{indent});
                break;
            };
            // #69 / #pattern-b-loop-in-arm: a non-switch OpBranch to a LOOP HEADER must be
            // followed, not treated as end-of-branch. Otherwise a loop nested in this arm is
            // silently dropped (early_return2: the else branch flows into a for-loop; emitBlock
            // stopped at the OpBranch and never reached the OpLoopMerge -> emitWhileLoop), and
            // so is every instruction after it in the arm. isLoopHeaderGLSL carries the scan
            // rule; see its doc comment for why a phi-only scan misses Pattern B.
            if (isLoopHeaderGLSL(m, lm, br_target)) continue;
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
                var phi_decls2 = std.ArrayList(PhiDeclGLSL).initCapacity(alloc, 4) catch unreachable;
                defer phi_decls2.deinit(alloc);
                if (merge_idx2 < m.instructions.len) {
                    var mi3: usize = merge_idx2 + 1;
                    while (mi3 < m.instructions.len) : (mi3 += 1) {
                        const minst = m.instructions[mi3];
                        if (minst.op != .Phi) break;
                        // #loop-merge-phi: a carrier renamed to `v<id>_lm` by the
                        // enclosing loop is owned there (reachable when this arm's
                        // selection merge IS the loop's merge, e.g. a synthesized
                        // SelectionMerge keyed to the loop merge); materializing it
                        // as a `_phi` temp would shadow the carrier the loop's exit
                        // paths write.
                        if (names.get(minst.words[2])) |ex2| {
                            if (std.mem.endsWith(u8, ex2, "_lm")) continue;
                        }
                        if (minst.words.len >= 7) {
                            phi_decls2.append(alloc, .{ .result_id = minst.words[2], .type_id = minst.words[1], .vals = .{ minst.words[3], minst.words[5] }, .preds = .{ minst.words[4], minst.words[6] } }) catch {};
                        }
                    }
                }
                // #no-then-selection (as in emitBody): the BC's TRUE target is its own
                // SelectionMerge. Walking tl as an arm walks the merge block inside
                // the if, duplicating its content; emit inverted instead.
                if (tl == nmv and fl != null) {
                    const bc_blk = blockLabelOfGLSL(m, i);
                    // #no-then: as in emitBody -- first-two-preds assumption guard.
                    if (!noThenMergePhisAreTwoPredGLSL(m, lm, nmv)) return error.UnsupportedLadderPhiScope;
                    for (phi_decls2.items) |pv| {
                        if (pv.preds[0] != bc_blk and pv.preds[1] != bc_blk) return error.UnsupportedLadderPhiScope;
                    }
                    for (phi_decls2.items) |pv| {
                        var tv: u32 = pv.vals[0];
                        var fv: u32 = pv.vals[1];
                        if (pv.preds[0] != bc_blk) {
                            tv = pv.vals[1];
                            fv = pv.vals[0];
                        }
                        const tvn = exprName(m, names, tv, alloc);
                        const vn_x = names.get(pv.result_id) orelse "pv";
                        // #ladder-phi-hoist: pre-declared at an outer arm top; keep
                        // the fall-through init as an assignment.
                        if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                            try w.print("{s}    {s}_phi = {s};\n", .{ indent, vn_x, tvn });
                            continue;
                        }
                        const rtt = try glslType(m, pv.type_id, names, alloc);
                        try w.print("{s}    {s} {s}_phi = {s};\n", .{ indent, rtt, vn_x, tvn });
                    }
                    try w.print("{s}    if (!({s}))\n{s}    {{\n", .{ indent, cn, indent });
                    {
                        // The hoist's arm-side values: the incoming whose pred is NOT
                        // the BC's own block (computable before the walk).
                        var fsides4 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                        defer fsides4.deinit(alloc);
                        for (phi_decls2.items) |pv| {
                            var fv: u32 = pv.vals[1];
                            if (pv.preds[1] == bc_blk) fv = pv.vals[0];
                            fsides4.append(alloc, fv) catch {};
                        }
                        try hoistArmIncomingPhisGLSL(m, names, lm, w, alloc, phi_decls2.items, fsides4.items, fl.?, nmv, indent);
                    }
                    i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent, false);
                    // The ARM-EXIT pred: emitBlock returns at the arm's terminator,
                    // so the recomputed label IS the arm-exit block (polarity probe:
                    // nothen_nested -- the c-false copy must take the ARM's incoming).
                    const arm_exit4 = blockLabelOfGLSL(m, i);
                    for (phi_decls2.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        var fv: u32 = pv.vals[1];
                        if (pv.preds[1] != arm_exit4) fv = pv.vals[0];
                        const fvn = exprName(m, names, fv, alloc);
                        try w.print("{s}        {s}_phi = {s};\n", .{ indent, vn, fvn });
                    }
                    try w.print("{s}    }}\n", .{indent});
                    for (phi_decls2.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                        if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                    }
                    if (lm.get(nmv)) |nmi2| {
                        i = nmi2;
                    }
                    continue;
                }
                for (phi_decls2.items) |pv| {
                    // #ladder-phi-hoist: pre-declared at an outer arm top; a skipped
                    // no-else init keeps its assignment (see emitBody's twin).
                    if (g_predeclared_arm_phis_init and g_predeclared_arm_phis.contains(pv.result_id)) {
                        if (!he) {
                            const fvv = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            const fvn0 = exprName(m, names, fvv, alloc);
                            const vn0 = names.get(pv.result_id) orelse "pv";
                            try w.print("{s}    {s}_phi = {s};\n", .{ indent, vn0, fvn0 });
                        }
                        continue;
                    }
                    const rtt = try glslType(m, pv.type_id, names, alloc);
                    const vn = names.get(pv.result_id) orelse "pv";
                    if (he) {
                        try w.print("{s}    {s} {s}_phi;\n", .{ indent, rtt, vn });
                    } else {
                        const false_val = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                        // #ladder-phi-scope: as in emitBody/emitWhileLoop -- a selection-
                        // level init reading an arm-internal phi is out of scope.
                        if (armRegionHasPhiGLSL(m, lm, .{ false_val, false_val }, tl, merge_idx2)) return error.UnsupportedLadderPhiScope;
                        const fvn = exprName(m, names, false_val, alloc);
                        try w.print("{s}    {s} {s}_phi = {s};\n", .{ indent, rtt, vn, fvn });
                    }
                }
                try w.print("{s}    if ({s})\n{s}    {{\n", .{ indent, cn, indent });
                // #ladder-phi-hoist: declare arm-side incomings that are arm-internal
                // phis at the ARM TOP (before the nested braces).
                if (tl != nmv) {
                    var tsides2 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                    defer tsides2.deinit(alloc);
                    for (phi_decls2.items) |pv| {
                        const tv = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                        tsides2.append(alloc, tv) catch {};
                    }
                    try hoistArmIncomingPhisGLSL(m, names, lm, w, alloc, phi_decls2.items, tsides2.items, tl, nmv, indent);
                }
                // #switch-arm-break (conditional): an arm DIRECTLY targeting the
                // enclosing switch's merge is a conditional break out of the switch.
                // The old path walked the arm, re-emitting the switch's MERGE block
                // inline inside the arm without this predecessor's phi copy -- the
                // merge phi kept whatever the normal path left in it (silent-wrong
                // on a VALID shape: a producer-lowered flag break branches to the
                // switch merge right after a loop, exactly this). The per-arm
                // assignments below are suppressed for a breaking arm (dead after
                // the break). Port of MSL/HLSL.
                const sctx_bc = g_switch_ctx_glsl;
                const tl_is_swbreak = if (sctx_bc) |sc| tl == sc.merge_label else false;
                const fl_is_swbreak = if (sctx_bc) |sc| (fl != null and fl.? == sc.merge_label) else false;
                if (tl_is_swbreak) {
                    try emitSwitchMergeBreakGLSL(m, names, sctx_bc.?, blockLabelOfGLSL(m, i), indent, w, alloc);
                } else {
                    i = try emitBlock(m, names, decs, tl, nmv, lm, bm, w, alloc, is_frag, ovid, indent, false);
                    for (phi_decls2.items) |pv| {
                        const vn = names.get(pv.result_id) orelse "pv";
                        const true_val = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[1] else pv.vals[0];
                        const tvn = exprName(m, names, true_val, alloc);
                        try w.print("{s}        {s}_phi = {s};\n", .{ indent, vn, tvn });
                    }
                }
                if (he) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    {
                        var fsides2 = std.ArrayList(u32).initCapacity(alloc, 4) catch unreachable;
                        defer fsides2.deinit(alloc);
                        for (phi_decls2.items) |pv| {
                            const fv = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            fsides2.append(alloc, fv) catch {};
                        }
                        try hoistArmIncomingPhisGLSL(m, names, lm, w, alloc, phi_decls2.items, fsides2.items, fl.?, nmv, indent);
                    }
                    if (fl_is_swbreak) {
                        try emitSwitchMergeBreakGLSL(m, names, sctx_bc.?, blockLabelOfGLSL(m, i), indent, w, alloc);
                    } else {
                        i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent, false);
                        for (phi_decls2.items) |pv| {
                            const vn = names.get(pv.result_id) orelse "pv";
                            const false_val = if (phiPred1InTrueRegion(m, lm, tl, nmv, pv.preds[1], alloc)) pv.vals[0] else pv.vals[1];
                            const fvn = exprName(m, names, false_val, alloc);
                            try w.print("{s}        {s}_phi = {s};\n", .{ indent, vn, fvn });
                        }
                    }
                }
                try w.print("{s}    }}\n", .{indent});
                for (phi_decls2.items) |pv| {
                    const vn = names.get(pv.result_id) orelse "pv";
                    const phi_name = try std.fmt.allocPrint(alloc, "{s}_phi", .{vn});
                    if (names.fetchPut(pv.result_id, phi_name) catch null) |old| alloc.free(old.value);
                }
                if (lm.get(nmv)) |nmi| {
                    i = nmi;
                }
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
                // #third-switch-site: this is emitBlock's own OpSwitch handler (a switch
                // nested in a selection arm or a case) -- the third GLSL switch site.
                // Materialize the switch-merge phis and ctx-wire the walker exactly as
                // emitBody's site does (port of MSL, which wires all three sites): without
                // this, the merge phi fell through to the generic OpPhi walker, which
                // honest-errored UnsupportedPhiAlias (MSL compiles the same shader).
                var sphis: std.ArrayList(Instruction) = .empty;
                defer sphis.deinit(alloc);
                collectSwitchMergePhis(m, lm, smv, &sphis, alloc);
                try emitSwitchPhiDecls(m, names, sphis.items, w, alloc);
                const saved_switch_ctx = g_switch_ctx_glsl;
                g_switch_ctx_glsl = .{ .merge_label = smv, .phis = sphis.items };
                defer g_switch_ctx_glsl = saved_switch_ctx;
                try w.print("{s}    switch ({s}) {{\n", .{ indent, sn });
                // Emit case targets FIRST, then `default` LAST (fallthrough-into-default,
                // matching emitBody's site). Braces per case: #switch-case-scope.
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == smv) continue;
                    // #continue-in-switch (case target IS the loop continue): see emitBody.
                    if (g_loop_merge_ctx) |ctx| if (ctx.continue_label == target) {
                        try w.print("{s}    case {d}: {{\n", .{ indent, switchCaseLiteral(m, inst.words[1], cv) });
                        if (g_loop_merge_ctx) |lctx| try emitLatchPhiCopiesGLSL(m, names, lm, lctx.continue_label, target, w, alloc);
                        try w.print("{s}    continue;\n{s}    }}\n", .{ indent, indent });
                        continue;
                    };
                    try w.print("{s}    case {d}: {{\n", .{ indent, switchCaseLiteral(m, inst.words[1], cv) });
                    // Buffered so the trailing `break;` can be skipped when the body
                    // already left the switch on its own (#dead-case-break).
                    var cb: std.ArrayList(u8) = .empty;
                    defer cb.deinit(alloc);
                    _ = try emitBlock(m, names, decs, target, smv, lm, bm, compat.listWriter(&cb, alloc), alloc, is_frag, ovid, indent, false);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, target, compat.listWriter(&cb, alloc), alloc);
                    try w.writeAll(cb.items);
                    // #switch-fallthrough: omit `break;` only on a real fallthrough edge
                    // into another case of THIS switch (never the merge) -- see emitBody.
                    const cterm = caseTerminatorTargetGLSL(m, lm, target);
                    const fallthrough = if (cterm) |t| (t != smv and isSwitchCaseTargetGLSL(inst.words, t)) else false;
                    if (!fallthrough and !caseBodyTerminates(cb.items)) try w.print("{s}    break;\n", .{indent});
                    try w.print("{s}    }}\n", .{indent});
                }
                if (dl != smv) {
                    try w.print("{s}    default: {{\n", .{indent});
                    var db: std.ArrayList(u8) = .empty;
                    defer db.deinit(alloc);
                    _ = try emitBlock(m, names, decs, dl, smv, lm, bm, compat.listWriter(&db, alloc), alloc, is_frag, ovid, indent, false);
                    try emitSwitchPhiCaseCopy(m, names, sphis.items, dl, compat.listWriter(&db, alloc), alloc);
                    try w.writeAll(db.items);
                    if (!caseBodyTerminates(db.items)) try w.print("{s}    break;\n", .{indent});
                    try w.print("{s}    }}\n", .{indent});
                }
                try w.print("{s}    }}\n", .{indent});
                finalizeSwitchPhis(names, sphis.items, alloc);
                if (lm.get(smv)) |smi| {
                    i = smi;
                }
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
                        try w.print("{s}case {d}:\n", .{ indent, switchCaseLiteral(m, inst.words[1], cv) });
                        i = try emitBlock(m, names, decs, target, sm2, lm, bm, w, alloc, is_frag, ovid, indent, true);
                    }
                    try w.print("{s}}}\n", .{indent});
                    if (lm.get(sm2)) |smi| {
                        i = smi;
                    }
                } else {
                    try w.writeAll("    // switch: no merge info\n");
                }
            }
            continue;
        }
        // #70: a function return / discard TERMINATES this block — emit it and stop. Without
        // this, emitBlock continued past an early OpReturn into the merge block, nesting the
        // next if inside the branch + duplicating it (multi-return-paths: control flow
        // mis-structured). The terminator is emitted (always `return;`/`discard;`), then we
        // break so emitBlock returns at the return, not past it.
        if (inst.op == .Return or inst.op == .ReturnValue or inst.op == .Kill) {
            try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
            break;
        }
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
    }
    return i;
}

/// Lower a subgroup ARITHMETIC op (IAdd/FAdd/IMul/FMul/Min/Max/Bitwise/Logical)
/// honoring the GroupOperation literal. SPIR-V layout for these ops:
///   words[1]=ResultType words[2]=Result words[3]=Execution(Scope <id>)
///   words[4]=GroupOperation literal (0=Reduce, 1=InclusiveScan,
///            2=ExclusiveScan, 3=ClusteredReduce)
///   words[5]=Value <id>  words[6]=ClusterSize <id> (ClusteredReduce only)
/// The old code read words[4] as the value; it is the GroupOperation literal, so
/// the value silently fell back to "x" AND every variant lowered as Reduce.
/// GL_KHR_shader_subgroup_arithmetic is regular: subgroup{,Inclusive,Exclusive,
/// Clustered}{Add,Mul,Min,Max,And,Or,Xor}; the cluster form takes (value, N).
/// (#subgroup-operand)
fn glslEmitSubgroupArith(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    inst: Instruction,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    if (inst.words.len < 6) return error.UnsupportedOp;
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const rn = names.get(inst.words[2]) orelse "v";
    const gop = inst.words[4];
    const val = names.get(inst.words[5]) orelse "x";
    // GL_KHR_shader_subgroup_arithmetic stem per op. LogicalAnd/LogicalOr reuse
    // the integer And/Or stems (matches the prior Reduce-only behavior).
    const stem: []const u8 = switch (inst.op) {
        .GroupNonUniformIAdd, .GroupNonUniformFAdd => "Add",
        .GroupNonUniformIMul, .GroupNonUniformFMul => "Mul",
        .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => "Min",
        .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => "Max",
        .GroupNonUniformBitwiseAnd, .GroupNonUniformLogicalAnd => "And",
        .GroupNonUniformBitwiseOr, .GroupNonUniformLogicalOr => "Or",
        .GroupNonUniformBitwiseXor => "Xor",
        else => return error.UnsupportedOp,
    };
    switch (gop) {
        0 => try w.print("    {s} {s} = subgroup{s}({s});\n", .{ rtt, rn, stem, val }),
        1 => try w.print("    {s} {s} = subgroupInclusive{s}({s});\n", .{ rtt, rn, stem, val }),
        2 => try w.print("    {s} {s} = subgroupExclusive{s}({s});\n", .{ rtt, rn, stem, val }),
        3 => {
            if (inst.words.len < 7) return error.UnsupportedOp;
            // words[6] is the ClusterSize Constant <id>, not a literal. The names map
            // resolves it normally (e.g. "4u"); if it is somehow unnamed, resolve the
            // constant value rather than emit the <id> number (silent-wrong), else honest-error.
            const cluster: []const u8 = names.get(inst.words[6]) orelse blk: {
                const cdef = getDef(m, inst.words[6]) orelse return error.UnsupportedOp;
                if (cdef.op != .Constant or cdef.words.len < 4) return error.UnsupportedOp;
                break :blk std.fmt.allocPrint(alloc, "{d}u", .{cdef.words[3]}) catch return error.OutOfMemory;
            };
            try w.print("    {s} {s} = subgroupClustered{s}({s}, {s});\n", .{ rtt, rn, stem, val, cluster });
        },
        else => return error.UnsupportedOp,
    }
}

fn emitInstruction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    inst: Instruction,
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    ovid: ?u32,
) !void {
    // #413: this instruction defines a loop-carried phi update temp whose
    // declaration was hoisted above the loop — re-render it with the type
    // stripped so it assigns the hoisted variable instead of redeclaring it
    // in an inner scope.
    if (!g_hoist_stripping) {
        if (g_hoisted_ids) |h| {
            if (resultIdFromOp(inst.op, inst.words)) |rid| {
                if (h.contains(rid)) {
                    g_hoist_stripping = true;
                    defer g_hoist_stripping = false;
                    var hbuf: std.ArrayList(u8) = .empty;
                    defer hbuf.deinit(alloc);
                    try emitInstruction(m, names, decs, inst, compat.listWriter(&hbuf, alloc), alloc, is_frag, ovid);
                    try common.writeHoistedAssign(w, hbuf.items, names.get(rid) orelse "");
                    return;
                }
            }
        }
    }
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
            // #476: OpVariable Function with an Initializer operand (word[4]) — emit it,
            // else the local reads zero/garbage before any store (silent-wrong). Mirrors HLSL.
            if (inst.words.len >= 5) {
                if (names.get(inst.words[4])) |in| {
                    try w.print("    {s} {s}{s} = {s};\n", .{ tn, names.get(ri) orelse "var", arr_suffix, in });
                    return;
                }
            }
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
                // #loop-merge-phi: a carrier renamed to `v<id>_lm` by the loop
                // walker is owned there (declared above the loop, assigned per
                // exit path). Same skip, same reason.
                if (std.mem.endsWith(u8, existing, "_lm")) return;
            }
            if (inst.words.len < 4) return;
            // A #413-hoisted phi and a loop-header phi already have a correct variable
            // and correct assignments under their own name; keep it. Same two exclusions
            // the MSL and HLSL arms make.
            {
                const owned = (if (g_hoisted_ids) |h| h.contains(inst.words[2]) else false) or
                    (if (g_phi_hdr) |ph| ph.get(inst.words[2]) != null else false);
                if (owned) return;
            }
            const fv = inst.words[3];
            const result_id = inst.words[2];
            // Aliasing to incoming[0] is only sound when every predecessor carries the
            // SAME id -- then the phi is degenerate and the choice does not matter. With
            // distinct incoming values it silently yields the FIRST predecessor's value
            // on every path, and no mechanism owns this phi, so there is no assignment
            // anywhere that would make it right. Refuse instead of miscompiling.
            // Ports #565 (MSL) and #567 (HLSL); GLSL was the last backend without it.
            {
                var pi: usize = 5;
                while (pi < inst.words.len) : (pi += 2) {
                    if (inst.words[pi] != fv) return error.UnsupportedPhiAlias;
                }
            }
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
        .FAdd, .IAdd => try common.emitBinOp(m, names, inst, "+", w, alloc, glslType),
        .FSub, .ISub => try common.emitBinOp(m, names, inst, "-", w, alloc, glslType),
        .FMul, .IMul => try common.emitBinOp(m, names, inst, "*", w, alloc, glslType),
        .FDiv, .SDiv, .UDiv => try common.emitBinOp(m, names, inst, "/", w, alloc, glslType),
        .FMod => {
            // OpFMod takes the sign of operand 2 (the divisor) -- exactly GLSL mod()'s
            // floor-based semantics (`x - y*floor(x/y)`), so mod() is correct here.
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = mod({s}, {s});\n", .{
                rtt,
                names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "a",
                names.get(inst.words[4]) orelse "b",
            });
        },
        .FRem => {
            // OpFRem takes the sign of operand 1 (the DIVIDEND) -- C fmod / truncation,
            // NOT GLSL mod() (which is floor-based = sign of the divisor and differs for
            // opposite-sign operands). GLSL has no fmod, so emit the truncation form
            // `a - b*trunc(a/b)`. The MSL/HLSL/WGSL backends already get FRem right
            // (fmod / float `%`); GLSL was the lone backend miscompiling it to mod(). (#170)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const a = names.get(inst.words[3]) orelse "a";
            const b = names.get(inst.words[4]) orelse "b";
            try w.print("    {s} {s} = {s} - {s} * trunc({s} / {s});\n", .{
                rtt, names.get(inst.words[2]) orelse "v", a, b, a, b,
            });
        },
        // GLSL `%` is FLOORED (sign of the divisor) -- glslang emits OpSMod for GLSL `int %`
        // -- so it is correct for OpSMod and OpUMod, but WRONG for OpSRem, which is truncated
        // (sign of the DIVIDEND). Emit `x - y*(x/y)` for SRem (GLSL `/` truncates toward
        // zero, giving the truncated remainder). Componentwise. GLSL was the lone backend
        // getting SRem wrong (WGSL/HLSL/MSL `%` is already truncated). (#170)
        .UMod, .SMod => try common.emitBinOp(m, names, inst, "%", w, alloc, glslType),
        .SRem => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const x = names.get(inst.words[3]) orelse "a";
            const y = names.get(inst.words[4]) orelse "b";
            try w.print("    {s} {s} = {s} - {s} * ({s} / {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", x, y, x, y });
        },
        .FNegate, .SNegate => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try common.emitBinOp(m, names, inst, "*", w, alloc, glslType),
        .Dot => try common.emitCall(m, names, inst, "dot", w, alloc, glslType),
        .Transpose => try common.emitCall(m, names, inst, "transpose", w, alloc, glslType),
        // GLSL has a native outerProduct(c, r); SPIR-V OpOuterProduct uses the same
        // operand order. Without this arm it fell through to `// unhandled op 147`,
        // leaving the result id undefined at its use sites.
        .OuterProduct => try common.emitCall(m, names, inst, "outerProduct", w, alloc, glslType),
        .FOrdEqual, .IEqual, .LogicalEqual => try emitRelOp(m, names, inst, "==", "equal", w, alloc),
        .FUnordEqual => try emitUnordEqual(m, names, inst, w, alloc),
        .FUnordNotEqual, .INotEqual, .LogicalNotEqual => try emitRelOp(m, names, inst, "!=", "notEqual", w, alloc),
        .FOrdNotEqual => try emitOrdNotEqual(m, names, inst, w, alloc),
        .FOrdLessThan, .SLessThan, .ULessThan => try emitRelOp(m, names, inst, "<", "lessThan", w, alloc),
        .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitRelOp(m, names, inst, ">", "greaterThan", w, alloc),
        .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitRelOp(m, names, inst, "<=", "lessThanEqual", w, alloc),
        .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitRelOp(m, names, inst, ">=", "greaterThanEqual", w, alloc),
        // #170: unordered float inequalities are TRUE on NaN, so `!(ordered complement)`
        // (scalar) / `not(complementFunc(a,b))` (vector), not the naive ordered op (false
        // on NaN = plausible-but-wrong, as spirv-cross emits). See emitNegatedRelOp.
        // OpFUnordEqual is TRUE on NaN too and has no ordered complement (`!=` is true on
        // NaN), so it goes through emitUnordEqual (isnan||isnan||==, per-component for
        // vectors since GLSL has no componentwise || on bvec).
        .FUnordLessThan => try emitNegatedRelOp(m, names, inst, ">=", "greaterThanEqual", w, alloc),
        .FUnordGreaterThan => try emitNegatedRelOp(m, names, inst, "<=", "lessThanEqual", w, alloc),
        .FUnordLessThanEqual => try emitNegatedRelOp(m, names, inst, ">", "greaterThan", w, alloc),
        .FUnordGreaterThanEqual => try emitNegatedRelOp(m, names, inst, "<", "lessThan", w, alloc),
        .LogicalOr => try common.emitBinOp(m, names, inst, "||", w, alloc, glslType),
        .LogicalAnd => try common.emitBinOp(m, names, inst, "&&", w, alloc, glslType),
        .IsNan => try common.emitCall(m, names, inst, "isnan", w, alloc, glslType),
        .IsInf => try common.emitCall(m, names, inst, "isinf", w, alloc, glslType),
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
                // mix(false_val, true_val, bvec_condition) — GLSL mix with bvec selector.
                // For INTEGER operands this needs GL_EXT_shader_integer_mix (core mix is
                // genType=float only); flag it so the post-pass emits the extension.
                const result_is_int = blk: {
                    const rd = getDef(m, inst.words[1]) orelse break :blk false;
                    if (rd.op == .TypeInt) break :blk true;
                    if (rd.op == .TypeVector) {
                        const ed = getDef(m, rd.words[2]) orelse break :blk false;
                        break :blk ed.op == .TypeInt;
                    }
                    break :blk false;
                };
                if (result_is_int) g_int_mix_needed = true;
                try w.print("    {s} {s} = mix({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", false_name, true_name, cond_name });
            } else {
                try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", cond_name, true_name, false_name });
            }
        },
        .BitwiseOr => try common.emitBinOp(m, names, inst, "|", w, alloc, glslType),
        .BitwiseXor => try common.emitBinOp(m, names, inst, "^", w, alloc, glslType),
        .BitwiseAnd => try common.emitBinOp(m, names, inst, "&", w, alloc, glslType),
        .ShiftRightLogical, .ShiftRightArithmetic => try common.emitBinOp(m, names, inst, ">>", w, alloc, glslType),
        .ShiftLeftLogical => try common.emitBinOp(m, names, inst, "<<", w, alloc, glslType),
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
                rtt,                                 names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0", names.get(inst.words[6]) orelse "0",
            });
        },
        // OpBitFieldSExtract / OpBitFieldUExtract: value, offset, count → bitfieldExtract
        // (overloaded by the value's signedness, so a single GLSL builtin covers both).
        .BitFieldSExtract, .BitFieldUExtract => {
            if (inst.words.len < 6) return;
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = bitfieldExtract({s}, {s}, {s});\n", .{
                rtt,                                 names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0",
                names.get(inst.words[5]) orelse "0",
            });
        },
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU, .UConvert, .SConvert, .FConvert => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}({s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        .VectorExtractDynamic => {
            // Extract a component from a vector by a (possibly non-constant) index —
            // e.g. matrixColumn[i]. GLSL spells this vec[idx]; without this arm it fell
            // through to `// unhandled op 77` and emitted undeclared identifiers.
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}[{s}];\n", .{
                rtt,                                 names.get(inst.words[2]) orelse "e",
                names.get(inst.words[3]) orelse "v", names.get(inst.words[4]) orelse "0",
            });
        },
        .Bitcast => {
            // OpBitcast REINTERPRETS the bit pattern; it does not numerically convert.
            // GLSL spells a float<->int/uint reinterpret with the dedicated builtins;
            // a T(x) constructor would round/convert and silently produce the wrong
            // value (floatBitsToUint(2.5) must be 0x40200000, not 2). An int<->uint
            // bitcast is already bit-preserving through the constructor, so that case
            // keeps the plain cast.
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const x = names.get(inst.words[3]) orelse "0";
            const dst = spvScalarBase(m, inst.words[1]);
            const src_ty = if (getDef(m, inst.words[3])) |od| (if (od.words.len > 1) od.words[1] else 0) else 0;
            const src = spvScalarBase(m, src_ty);
            const builtin: ?[]const u8 = switch (dst) {
                .uint => if (src == .float) "floatBitsToUint" else null,
                .sint => if (src == .float) "floatBitsToInt" else null,
                .float => switch (src) {
                    .uint => "uintBitsToFloat",
                    .sint => "intBitsToFloat",
                    else => null,
                },
                .other => null,
            };
            if (builtin) |f| {
                try w.print("    {s} {s} = {s}({s});\n", .{ rtt, rn, f, x });
            } else {
                try w.print("    {s} {s} = {s}({s});\n", .{ rtt, rn, rtt, x });
            }
        },
        .CompositeConstruct => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            // glslType returns the ELEMENT type for an array result, so an array
            // composite ('vec4[2](a, b)') would wrongly emit 'vec4 name = vec4(a, b)'.
            // Build the full '[N][M]' dimension suffix (multi-dim, spec-const-aware)
            // and use the GLSL array-constructor form 'elem name[N] = elem[N](...)'.
            var dims = std.ArrayList(u8).initCapacity(alloc, 16) catch return error.OutOfMemory;
            defer dims.deinit(alloc);
            var cur = getDef(m, inst.words[1]);
            while (cur) |c| {
                if (c.op != .TypeArray or c.words.len < 4) break;
                const len_def = getDef(m, c.words[3]);
                const n: u32 = if (len_def) |ld| (if ((ld.op == .Constant or ld.op == .SpecConstant) and ld.words.len > 3) ld.words[3] else 0) else 0;
                dims.print(alloc, "[{d}]", .{n}) catch break;
                cur = getDef(m, c.words[2]);
            }
            const ds = dims.items;
            try w.print("    {s} {s}{s} = {s}{s}(", .{ rtt, names.get(inst.words[2]) orelse "v", ds, rtt, ds });
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
                    {
                        const soc = @intFromEnum(sd.op);
                        if (soc == 149 or soc == 150 or soc == 151) return;
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
            // #475: walk the type chain per-index level (was a single is_vec flag that
            // emitted [0] for struct members = GLSL compile error). Mirrors WGSL/HLSL.
            try w.print("    {s}", .{rname});
            var cur_type_id: ?u32 = getTypeOf(m, inst.words[4]);
            for (inst.words[5..]) |index| {
                if (cur_type_id) |ctid| {
                    if (getDef(m, ctid)) |ci| switch (ci.op) {
                        .TypeVector => {
                            try w.writeAll(swizzleChar(index));
                            cur_type_id = if (ci.words.len > 2) ci.words[2] else null;
                            continue;
                        },
                        .TypeStruct => {
                            var mb: [32]u8 = undefined;
                            try w.print(".{s}", .{getMemberName(m, ctid, index, &mb)});
                            cur_type_id = if (ci.words.len > 2 + index) ci.words[2 + index] else null;
                            continue;
                        },
                        else => {
                            try w.print("[{d}]", .{index});
                            cur_type_id = if (ci.words.len > 2) ci.words[2] else null;
                            continue;
                        },
                    };
                }
                try w.print("[{d}]", .{index});
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
        // #474: preserve the coarse/fine precision request. GLSL has the variants
        // natively (GL_ARB_derivative_control / 4.5 core); collapsing them to plain
        // dFdx/dFdy/fwidth silently changes the derivative (plain is impl-defined
        // coarse-or-fine). The extension is spliced when these tokens are emitted.
        .DPdx => try common.emitCall(m, names, inst, "dFdx", w, alloc, glslType),
        .DPdxCoarse => try common.emitCall(m, names, inst, "dFdxCoarse", w, alloc, glslType),
        .DPdxFine => try common.emitCall(m, names, inst, "dFdxFine", w, alloc, glslType),
        .DPdy => try common.emitCall(m, names, inst, "dFdy", w, alloc, glslType),
        .DPdyCoarse => try common.emitCall(m, names, inst, "dFdyCoarse", w, alloc, glslType),
        .DPdyFine => try common.emitCall(m, names, inst, "dFdyFine", w, alloc, glslType),
        .Fwidth => try common.emitCall(m, names, inst, "fwidth", w, alloc, glslType),
        .FwidthCoarse => try common.emitCall(m, names, inst, "fwidthCoarse", w, alloc, glslType),
        .FwidthFine => try common.emitCall(m, names, inst, "fwidthFine", w, alloc, glslType),
        .All => try common.emitCall(m, names, inst, "all", w, alloc, glslType),
        .Any => try common.emitCall(m, names, inst, "any", w, alloc, glslType),
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
            // Image operands: Bias (bit 0, 0x1) is the GLSL LOD bias; ConstOffset (bit 3,
            // 0x8) is a compile-time texel offset -> `textureOffset`. Values follow the mask
            // in ascending bit order (Bias before ConstOffset). Dropping either is
            // silent-wrong (wrong mip / wrong texel); the ConstOffset was previously discarded
            // here (`textureOffset(sampler2D, uv, off)` lowers to implicit-lod + ConstOffset). (#170)
            const mask: u32 = if (inst.words.len > 5) inst.words[5] else 0;
            const has_bias = (mask & 0x1) != 0;
            const has_offset = (mask & 0x8) != 0;
            const bias_idx: usize = 6; // Bias is the lowest operand bit, so its value is first
            const offset_idx: usize = if (has_bias) 7 else 6;
            const gname = names.get(inst.words[2]) orelse "v";
            if (has_offset and inst.words.len > offset_idx) {
                const off = names.get(inst.words[offset_idx]) orelse "ivec2(0)";
                if (has_bias and inst.words.len > bias_idx) {
                    try w.print("    {s} {s} = textureOffset({s}, {s}, {s}, {s});\n", .{ rtt, gname, si, coord, off, names.get(inst.words[bias_idx]) orelse "0.0" });
                } else {
                    try w.print("    {s} {s} = textureOffset({s}, {s}, {s});\n", .{ rtt, gname, si, coord, off });
                }
            } else if (has_bias and inst.words.len > bias_idx) {
                try w.print("    {s} {s} = texture({s}, {s}, {s});\n", .{ rtt, gname, si, coord, names.get(inst.words[bias_idx]) orelse "0.0" });
            } else {
                try w.print("    {s} {s} = texture({s}, {s});\n", .{ rtt, gname, si, coord });
            }
        },
        .ImageSampleDrefImplicitLod => {
            // Shadow compare: texture(sampler*Shadow, vecN(coord.leading, dref)). The
            // ctor width is sampler-dim-aware (see glslShadowCoordCtor) -- a glslang
            // producer packs the dref INTO the coord, so reading the coord width
            // double-counts it (vec4 where vec3 is needed). ConstOffset (0x8) ->
            // native textureOffset. Operand layout: Dref=words[5], mask=words[6],
            // values from words[7]. (#170)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const sc = glslShadowCoordCtor(m, inst.words[3], inst.words[4]);
            const cmp_coord = try std.fmt.allocPrint(alloc, "{s}({s}{s}, {s})", .{ sc.ctor, coord, sc.swizzle, dref });
            const gname = names.get(inst.words[2]) orelse "v";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                try w.print("    {s} {s} = textureOffset({s}, {s}, {s});\n", .{ rtt, gname, si, cmp_coord, names.get(inst.words[oi]) orelse "ivec2(0)" });
            } else {
                try w.print("    {s} {s} = texture({s}, {s});\n", .{ rtt, gname, si, cmp_coord });
            }
        },
        .ImageSampleDrefExplicitLod => {
            // Shadow compare with explicit LOD: textureLod(sampler*Shadow, ctor, lod).
            // The compare-coord ctor is sampler-dim-aware (see ImageSampleDrefImplicitLod).
            // Lod value at words[7] (bit 0x2; Dref=words[5], mask=words[6]); ConstOffset
            // (0x8) -> textureLodOffset. The Lod must be the real operand, not 0. (#170)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const lod: []const u8 = if (inst.words.len > 7 and (inst.words[6] & 0x2) != 0)
                names.get(inst.words[7]) orelse "0.0"
            else
                "0.0";
            const sc = glslShadowCoordCtor(m, inst.words[3], inst.words[4]);
            const cmp_coord = try std.fmt.allocPrint(alloc, "{s}({s}{s}, {s})", .{ sc.ctor, coord, sc.swizzle, dref });
            const gname = names.get(inst.words[2]) orelse "v";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                try w.print("    {s} {s} = textureLodOffset({s}, {s}, {s}, {s});\n", .{ rtt, gname, si, cmp_coord, lod, names.get(inst.words[oi]) orelse "ivec2(0)" });
            } else {
                try w.print("    {s} {s} = textureLod({s}, {s}, {s});\n", .{ rtt, gname, si, cmp_coord, lod });
            }
        },
        .ImageSampleProjImplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // Projected: textureProj(sampler, vec4(xy, z, w)) divides xy by w.
            // textureProjOffset carries a ConstOffset image operand (mask 0x8 at
            // words[5], offset at words[6]) — emit the native offset form. Dropping
            // it would silently sample the un-offset texels.
            if (inst.words.len > 6 and (inst.words[5] & 0x8) != 0) {
                try w.print("    {s} {s} = textureProjOffset({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[6]) orelse "ivec2(0)" });
            } else {
                try w.print("    {s} {s} = textureProj({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageSampleProjDrefImplicitLod => {
            // Projected shadow: textureProj(sampler2DShadow, vec4(xy, depth, w)).
            // Only 2D projective shadow is faithful here (the vec4 divides xy by w).
            // ConstOffset (0x8) -> textureProjOffset. Dref=words[5], mask=words[6]. (#170)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const gname = names.get(inst.words[2]) orelse "v";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                try w.print("    {s} {s} = textureProjOffset({s}, vec4({s}.xy, {s}, {s}.w), {s});\n", .{ rtt, gname, si, coord, dref, coord, names.get(inst.words[oi]) orelse "ivec2(0)" });
            } else {
                try w.print("    {s} {s} = textureProj({s}, vec4({s}.xy, {s}, {s}.w));\n", .{ rtt, gname, si, coord, dref, coord });
            }
        },
        .ImageSampleProjDrefExplicitLod => {
            // Projected shadow + explicit LOD. Lod value at words[7] (bit 0x2); the
            // old code hardcoded 0, silently sampling mip 0. ConstOffset (0x8) ->
            // textureProjLodOffset. (#170)
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const lod: []const u8 = if (inst.words.len > 7 and (inst.words[6] & 0x2) != 0)
                names.get(inst.words[7]) orelse "0.0"
            else
                "0.0";
            const gname = names.get(inst.words[2]) orelse "v";
            if (drefConstOffsetIdx(inst.words)) |oi| {
                try w.print("    {s} {s} = textureProjLodOffset({s}, vec4({s}.xy, {s}, {s}.w), {s}, {s});\n", .{ rtt, gname, si, coord, dref, coord, lod, names.get(inst.words[oi]) orelse "ivec2(0)" });
            } else {
                try w.print("    {s} {s} = textureProjLod({s}, vec4({s}.xy, {s}, {s}.w), {s});\n", .{ rtt, gname, si, coord, dref, coord, lod });
            }
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
                    const lod = names.get(inst.words[off]) orelse "0";
                    // Lod|ConstOffset (textureLodOffset): the const offset follows the
                    // lod. Dropping it silently samples the un-offset texels. (#170)
                    if (mask & 0x8 != 0 and off + 1 < inst.words.len) {
                        try w.print("    {s} {s} = textureLodOffset({s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, lod, names.get(inst.words[off + 1]) orelse "ivec2(0)" });
                    } else {
                        try w.print("    {s} {s} = textureLod({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, lod });
                    }
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    const dx = names.get(inst.words[off]) orelse "0";
                    const dy = names.get(inst.words[off + 1]) orelse "0";
                    // Grad|ConstOffset (textureGradOffset): the const offset follows
                    // both gradients. Dropping it would silently emit a plain
                    // textureGrad = wrong texels.
                    if (mask & 0x8 != 0 and off + 2 < inst.words.len) {
                        try w.print("    {s} {s} = textureGradOffset({s}, {s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dx, dy, names.get(inst.words[off + 2]) orelse "ivec2(0)" });
                    } else {
                        try w.print("    {s} {s} = textureGrad({s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, dx, dy });
                    }
                } else {
                    try w.print("    {s} {s} = textureLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
                }
            } else {
                try w.print("    {s} {s} = textureLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageSampleProjExplicitLod => {
            // Projected explicit LOD: textureProjLod (Lod) or textureProjGrad (Grad),
            // distinguished by the image-operands mask. GLSL has native builtins for both.
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    const lod = names.get(inst.words[off]) orelse "0";
                    // Lod|ConstOffset (textureProjLodOffset): native textureProjLodOffset
                    // carries the const offset after the lod. Dropping it would silently
                    // emit a plain textureProjLod = wrong texels.
                    if (mask & 0x8 != 0 and off + 1 < inst.words.len) {
                        try w.print("    {s} {s} = textureProjLodOffset({s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, lod, names.get(inst.words[off + 1]) orelse "ivec2(0)" });
                    } else {
                        try w.print("    {s} {s} = textureProjLod({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, lod });
                    }
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    const ddx = names.get(inst.words[off]) orelse "0";
                    const ddy = names.get(inst.words[off + 1]) orelse "0";
                    // Grad|ConstOffset (textureProjGradOffset): native textureProjGradOffset
                    // carries the const offset after both gradients.
                    if (mask & 0x8 != 0 and off + 2 < inst.words.len) {
                        try w.print("    {s} {s} = textureProjGradOffset({s}, {s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, ddx, ddy, names.get(inst.words[off + 2]) orelse "ivec2(0)" });
                    } else {
                        try w.print("    {s} {s} = textureProjGrad({s}, {s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, ddx, ddy });
                    }
                } else {
                    try w.print("    {s} {s} = textureProjLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
                }
            } else {
                try w.print("    {s} {s} = textureProjLod({s}, {s}, 0);\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageFetch => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            // Resolve the OpTypeImage behind the fetch operand (words[3]) to read Dim
            // (Buffer=5) and the multisample flag (MS=words[6]). The operand is an
            // OpSampledImage result or -- the common OpImageFetch shape -- an OpImage
            // result whose Result Type IS the OpTypeImage.
            const img_def = blk: {
                const sd = getDef(m, inst.words[3]) orelse break :blk null;
                if (sd.op == .SampledImage and sd.words.len > 2) break :blk getDef(m, sd.words[2]);
                if (sd.op == .OpImage and sd.words.len > 1) break :blk getDef(m, sd.words[1]);
                break :blk null;
            };
            const is_buffer = if (img_def) |id| (id.op == .TypeImage and id.words.len > 3 and id.words[3] == 5) else false;
            const is_ms = if (img_def) |id| (id.op == .TypeImage and id.words.len > 6 and id.words[6] == 1) else false;
            if (is_buffer) {
                // Buffer: texelFetch takes (sampler, coord) -- no LOD/sample arg.
                try w.print("    {s} {s} = texelFetch({s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0" });
            } else if (is_ms) {
                // Multisampled: texelFetch's 3rd arg is the SAMPLE index (NOT an LOD),
                // carried by the Sample image operand (mask 0x40, id at words[6]). MS
                // textures have no mip chain. Without this zioshade hardcoded 0, reading
                // only sample 0 from every per-sample fetch (silent-wrong). (#imagefetch)
                const sample: []const u8 = if (inst.words.len > 6 and (inst.words[5] & 0x40) != 0)
                    names.get(inst.words[6]) orelse "0"
                else
                    "0";
                try w.print("    {s} {s} = texelFetch({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0", sample });
            } else {
                // OpImageFetch: pass the explicit LOD (image-operand Lod bit 0x2, value at
                // words[6]) instead of hardcoding mip 0. `texelFetch` REQUIRES a lod arg for a
                // sampled 2D image, and dropping the operand silently read the base mip for any
                // `texelFetch(s, coord, lod>0)`. WGSL already passes it; HLSL/MSL still drop
                // it (validator-gated follow-up). (#170)
                const lod: []const u8 = if (inst.words.len > 6 and (inst.words[5] & 0x2) != 0)
                    names.get(inst.words[6]) orelse "0"
                else
                    "0";
                try w.print("    {s} {s} = texelFetch({s}, {s}, {s});\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0", lod });
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
            // Likewise textureGatherOffset's single ConstOffset (0x8) and any
            // runtime Offset (0x10): this plain textureGather emit carries no
            // offset, so honest-error on every offset-bearing operand bit
            // (0x38 = ConstOffset|Offset|ConstOffsets) rather than silent-drop.
            if (inst.words.len > 6 and (inst.words[6] & 0x38) != 0) {
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
            try w.print("    imageStore({s}, {s}, {s});\n", .{ img, coord, texel });
        },
        .ImageQuerySizeLod => {
            // OpImageQuerySizeLod: result_type, result, image, lod
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const lod = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            try w.print("    {s} {s} = textureSize({s}, {s});\n", .{ rtt, rn, img, lod });
        },
        .ImageQuerySize => {
            // OpImageQuerySize: result_type, result, image (no lod). A STORAGE image
            // (`image2D`, Sampled==2) has no LOD chain, so its size is queried with
            // `imageSize(img)` — `textureSize` is sampled-texture-only and glslang
            // rejects it on an image2D ("no matching overloaded function"). A sampled
            // texture that legitimately reaches OpImageQuerySize (multisample/buffer/
            // rect, also LOD-less) keeps the `textureSize(img, 0)` form.
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            if (imageOperandIsStorage(m, inst.words[3])) {
                try w.print("    {s} {s} = imageSize({s});\n", .{ rtt, rn, img });
            } else {
                try w.print("    {s} {s} = textureSize({s}, 0);\n", .{ rtt, rn, img });
            }
        },
        .ImageQueryLod => {
            // OpImageQueryLod: result_type, result, SampledImage, coord
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            const coord2 = if (inst.words.len > 4) names.get(inst.words[4]) orelse "vec2(0)" else "vec2(0)";
            try w.print("    {s} {s} = textureQueryLod({s}, {s});\n", .{ rtt, rn, img, coord2 });
        },
        .ImageQueryLevels => {
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    int {s} = textureQueryLevels({s});\n", .{ rn, img });
        },
        .ImageQuerySamples => {
            const rn = names.get(inst.words[2]) orelse "v";
            const img = names.get(inst.words[3]) orelse "tex";
            try w.print("    int {s} = textureSamples({s});\n", .{ rn, img });
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
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicISub => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, -{s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, -{s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicOr => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicOr({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicOr({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicXor => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicXor({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicXor({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicAnd => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAnd({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicAnd({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicSMin, .AtomicUMin => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicMin({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicMin({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicSMax, .AtomicUMax => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicMax({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicMax({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
            }
        },
        .AtomicExchange => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicExchange({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicExchange({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
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
                .ssbo => |ptr| try w.print("    {s} {s} = atomicCompSwap({s}, {s}, {s});\n", .{ rtt, rn, ptr, cmp, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicCompSwap({s}, {s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, cmp, val }),
            }
        },
        .AtomicFAddEXT => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0.0" else "0.0";
            switch (classifyAtomicPtr(m, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s} = atomicAdd({s}, {s});\n", .{ rtt, rn, ptr, val }),
                .image => |p| try w.print("    {s} {s} = imageAtomicAdd({s}, {s}, {s});\n", .{ rtt, rn, p.img, p.coord, val }),
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
            try w.print("    {s} {s} = subgroupAll({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformAny => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAny({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformAllEqual => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupAllEqual({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformBroadcast => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupBroadcast({s}, {s});\n", .{ rtt, rn, val, lane });
        },
        .GroupNonUniformBroadcastFirst => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupBroadcastFirst({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformBallot => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = subgroupBallot({s});\n", .{ rtt, rn, val });
        },
        .GroupNonUniformShuffle => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffle({s}, {s});\n", .{ rtt, rn, val, lane });
        },
        .GroupNonUniformShuffleXor => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const mask = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleXor({s}, {s});\n", .{ rtt, rn, val, mask });
        },
        .GroupNonUniformShuffleUp => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleUp({s}, {s});\n", .{ rtt, rn, val, delta });
        },
        .GroupNonUniformShuffleDown => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = subgroupShuffleDown({s}, {s});\n", .{ rtt, rn, val, delta });
        },
        // Subgroup ARITHMETIC ops share one lowering that honors the
        // GroupOperation literal (Reduce/InclusiveScan/ExclusiveScan/
        // ClusteredReduce); see glslEmitSubgroupArith for the operand fix.
        .GroupNonUniformIAdd, .GroupNonUniformFAdd, .GroupNonUniformIMul, .GroupNonUniformFMul, .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin, .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax, .GroupNonUniformBitwiseAnd, .GroupNonUniformBitwiseOr, .GroupNonUniformBitwiseXor, .GroupNonUniformLogicalAnd, .GroupNonUniformLogicalOr => {
            try glslEmitSubgroupArith(m, names, inst, w, alloc);
        },
        // SubgroupAllKHR / SubgroupAnyKHR
        .SubgroupAllKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = subgroupAll({s});\n", .{ rn, val });
        },
        .SubgroupAnyKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = subgroupAny({s});\n", .{ rn, val });
        },
        .Return => {
            // #70: always emit `return;`. The old `!(is_frag and ovid != null)` skip assumed
            // every fragment-shader return was the final one (output already written), so it
            // DROPPED early/multiple returns — control then fell through past where it should
            // have exited (multi-return-paths: 4 returns vanished). A trailing `return;` at
            // end-of-main is a harmless no-op; an early one is required for correctness.
            try w.writeAll("    return;\n");
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
                const rtt = try glslTypeWithDims(m, inst.words[1], names, alloc);
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
            // #carry-ops: OpIAddCarry (149) / OpISubBorrow (150) / OpUMulExtended
            // (151) -- struct-result ops with no GLSL struct equivalent; GLSL's
            // uaddCarry/usubBorrow/umulExtended take the members as OUT params.
            // Decomposed exactly like the std450 FrexpStruct/ModfStruct pair:
            // scan the downstream CompositeExtracts, steal their result names for
            // the members, emit the out-param + call; the extracts skip
            // themselves. (The spirv.Op enum is non-exhaustive and does not name
            // these -- match by raw opcode, as WGSL does.)
            {
                const opc = @intFromEnum(inst.op);
                if (opc == 149 or opc == 150 or opc == 151) {
                    // Scope gate: a carry op inside a LOOP is refused for now --
                    // GraphicsFuzz loop bodies read body-scoped temps after the
                    // loop (graphicsfuzz_058), and the escape hoist (declaring
                    // surviving body values at the enclosing scope) is its own
                    // piece of work. Top-level carries lower fully.
                    {
                        var self_idx: usize = 0;
                        for (m.instructions, 0..) |mi, ix| {
                            if (@intFromEnum(mi.op) == opc and mi.words.len >= 3 and mi.words[2] == inst.words[2]) {
                                self_idx = ix;
                                break;
                            }
                        }
                        // Tableless containment (review: a 16-entry region table
                        // silently DROPPED the 17th loop and let its carries
                        // through to the invalid escape output).
                        for (m.instructions, 0..) |mi, ix| {
                            if (mi.op != .LoopMerge or mi.words.len < 2) continue;
                            if (self_idx <= ix) continue;
                            var mj: usize = ix + 1;
                            while (mj < m.instructions.len) : (mj += 1) {
                                if (m.instructions[mj].op == .Label and m.instructions[mj].words.len > 1 and m.instructions[mj].words[1] == mi.words[1]) break;
                            }
                            if (mj < m.instructions.len and self_idx < mj) return error.UnsupportedCarryInLoop;
                        }
                    }
                }
                if (opc == 149 or opc == 150) {
                    if (inst.words.len < 5) return error.CrossCompileUnsupported;
                    const xn = exprName(m, names, inst.words[3], alloc);
                    const yn = exprName(m, names, inst.words[4], alloc);
                    const fn_name: []const u8 = if (opc == 149) "uaddCarry" else "usubBorrow";
                    // Fallback names minted from the result id (review: fixed
                    // strings redeclared across two carry ops in one function).
                    const lo_fb = std.fmt.allocPrint(alloc, "v{d}cylo", .{inst.words[2]}) catch return error.OutOfMemory;
                    const hi_fb = std.fmt.allocPrint(alloc, "v{d}cyhi", .{inst.words[2]}) catch return error.OutOfMemory;
                    var lo_name: []const u8 = lo_fb;
                    var hi_name: []const u8 = hi_fb;
                    var t_name: []const u8 = "uint";
                    {
                        var j: usize = 0;
                        for (m.instructions, 0..) |mi, i| {
                            if (@intFromEnum(mi.op) == opc and mi.words.len >= 3 and mi.words[2] == inst.words[2]) {
                                j = i + 1;
                                break;
                            }
                        }
                        while (j < m.instructions.len) : (j += 1) {
                            const ni = m.instructions[j];
                            if (ni.op == .FunctionEnd) break;
                            if (ni.op == .CompositeExtract and ni.words.len >= 5 and ni.words[3] == inst.words[2]) {
                                // Multi-index (lane) extracts on vector carries are NOT
                                // member selects (review) -- honest error rather than a
                                // misread.
                                if (ni.words.len > 5) return error.UnsupportedCarryMemberAccess;
                                const nm = names.get(ni.words[2]) orelse "v";
                                if (ni.words[4] == 0) {
                                    // A SECOND extract of the same member aliases the
                                    // member variable (review: last-wins left the other
                                    // extract's name dangling).
                                    if (lo_name.ptr != lo_fb.ptr) {
                                        if (names.fetchPut(ni.words[2], lo_name) catch null) |oldn| alloc.free(oldn.value);
                                        continue;
                                    }
                                    lo_name = nm;
                                } else {
                                    if (hi_name.ptr != hi_fb.ptr) {
                                        if (names.fetchPut(ni.words[2], hi_name) catch null) |oldn| alloc.free(oldn.value);
                                        continue;
                                    }
                                    hi_name = nm;
                                }
                                t_name = try glslType(m, ni.words[1], names, alloc);
                            }
                        }
                    }
                    try w.print("    {s} {s};\n", .{ t_name, hi_name });
                    try w.print("    {s} {s} = {s}({s}, {s}, {s});\n", .{ t_name, lo_name, fn_name, xn, yn, hi_name });
                    return;
                }
                if (opc == 151) {
                    // OpUMulExtended returns {low, high}; GLSL's umulExtended is
                    // void with BOTH members as out-params (call order: msb, lsb).
                    if (inst.words.len < 5) return error.CrossCompileUnsupported;
                    const xn = exprName(m, names, inst.words[3], alloc);
                    const yn = exprName(m, names, inst.words[4], alloc);
                    const lo_fb2 = std.fmt.allocPrint(alloc, "v{d}mulo", .{inst.words[2]}) catch return error.OutOfMemory;
                    const hi_fb2 = std.fmt.allocPrint(alloc, "v{d}mulh", .{inst.words[2]}) catch return error.OutOfMemory;
                    var lo_name: []const u8 = lo_fb2;
                    var hi_name: []const u8 = hi_fb2;
                    var t_name: []const u8 = "uint";
                    {
                        var j: usize = 0;
                        for (m.instructions, 0..) |mi, i| {
                            if (@intFromEnum(mi.op) == 151 and mi.words.len >= 3 and mi.words[2] == inst.words[2]) {
                                j = i + 1;
                                break;
                            }
                        }
                        while (j < m.instructions.len) : (j += 1) {
                            const ni = m.instructions[j];
                            if (ni.op == .FunctionEnd) break;
                            if (ni.op == .CompositeExtract and ni.words.len >= 5 and ni.words[3] == inst.words[2]) {
                                if (ni.words.len > 5) return error.UnsupportedCarryMemberAccess;
                                const nm = names.get(ni.words[2]) orelse "v";
                                if (ni.words[4] == 0) {
                                    if (lo_name.ptr != lo_fb2.ptr) {
                                        if (names.fetchPut(ni.words[2], lo_name) catch null) |oldn| alloc.free(oldn.value);
                                        continue;
                                    }
                                    lo_name = nm;
                                } else {
                                    if (hi_name.ptr != hi_fb2.ptr) {
                                        if (names.fetchPut(ni.words[2], hi_name) catch null) |oldn| alloc.free(oldn.value);
                                        continue;
                                    }
                                    hi_name = nm;
                                }
                                t_name = try glslType(m, ni.words[1], names, alloc);
                            }
                        }
                    }
                    try w.print("    {s} {s};\n", .{ t_name, lo_name });
                    try w.print("    {s} {s};\n", .{ t_name, hi_name });
                    try w.print("    umulExtended({s}, {s}, {s}, {s});\n", .{ xn, yn, hi_name, lo_name });
                    return;
                }
            }
            // An unhandled opcode has no GLSL lowering. Emitting a `// unhandled op N`
            // comment and continuing leaves the result undefined at every use site =
            // invalid GLSL at exit 0 (the silent-wrong class this project exists to
            // prevent). If the result is consumed, REFUSE loudly; only a genuinely
            // dead result keeps the harmless comment. (Advanced image/tensor/ray-query
            // opcodes with no GLSL equivalent; OpUndef from a lost frontend result.)
            // An unknown opcode is NOT registered in id_defs, so getDef(result) is
            // null — detect a value result via the TYPE operand instead (words[1]
            // resolves to a Type* instruction for every result-producing op; for a
            // no-result op like OpStore it resolves to a value/pointer, so this stays
            // false and the op keeps its harmless comment).
            const rid: u32 = if (inst.words.len >= 3) inst.words[2] else 0;
            const produces_result = rid != 0 and blk: {
                const td = getDef(m, inst.words[1]) orelse break :blk false;
                break :blk switch (td.op) {
                    .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix, .TypeArray, .TypeRuntimeArray, .TypeStruct, .TypePointer, .TypeImage, .TypeSampledImage, .TypeSampler => true,
                    else => false,
                };
            };
            if (produces_result and resultIsReferenced(m, rid)) return error.CrossCompileUnsupported;
            try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
        },
    }
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
