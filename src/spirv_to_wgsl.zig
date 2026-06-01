// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → WGSL (WebGPU Shading Language) cross-compiler backend.

const std = @import("std");
const spirv = @import("spirv.zig");
const common = @import("spirv_cross_common.zig");

const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = common.DecorationEntry;

/// Human-readable detail for the most recent `error.UnsupportedExtInst`. Zig
/// errors carry no payload, so the failing GLSL.std.450 instruction is recorded
/// here for the CLI/tests to surface (e.g. "GLSL.std.450 InterpolateAtCentroid
/// (76) has no WGSL equivalent"). Backed by a threadlocal buffer; valid until
/// the next `spirvToWGSL` call on the same thread. Reset at `spirvToWGSL` entry.
pub threadlocal var last_error_detail: ?[]const u8 = null;
threadlocal var last_error_detail_buf: [192]u8 = undefined;

/// Canonical GLSL.std.450 instruction name, for diagnostics only.
fn glslStd450Name(op: u32) []const u8 {
    return switch (op) {
        1 => "Round", 2 => "RoundEven", 3 => "Trunc", 4 => "FAbs", 5 => "SAbs",
        6 => "FSign", 7 => "SSign", 8 => "Floor", 9 => "Ceil", 10 => "Fract",
        11 => "Radians", 12 => "Degrees", 13 => "Sin", 14 => "Cos", 15 => "Tan",
        16 => "Asin", 17 => "Acos", 18 => "Atan", 19 => "Sinh", 20 => "Cosh",
        21 => "Tanh", 22 => "Asinh", 23 => "Acosh", 24 => "Atanh", 25 => "Atan2",
        26 => "Pow", 27 => "Exp", 28 => "Log", 29 => "Exp2", 30 => "Log2",
        31 => "Sqrt", 32 => "InverseSqrt", 33 => "Determinant", 34 => "MatrixInverse",
        35 => "Modf", 36 => "ModfStruct", 37 => "FMin", 38 => "UMin", 39 => "SMin",
        40 => "FMax", 41 => "UMax", 42 => "SMax", 43 => "FClamp", 44 => "UClamp",
        45 => "SClamp", 46 => "FMix", 47 => "IMix", 48 => "Step", 49 => "SmoothStep",
        50 => "Fma", 51 => "Frexp", 52 => "FrexpStruct", 53 => "Ldexp",
        54 => "PackSnorm4x8", 55 => "PackUnorm4x8", 56 => "PackSnorm2x16",
        57 => "PackUnorm2x16", 58 => "PackHalf2x16", 59 => "PackDouble2x32",
        60 => "UnpackSnorm2x16", 61 => "UnpackUnorm2x16", 62 => "UnpackHalf2x16",
        63 => "UnpackSnorm4x8", 64 => "UnpackUnorm4x8", 65 => "UnpackDouble2x32",
        66 => "Length", 67 => "Distance", 68 => "Cross", 69 => "Normalize",
        70 => "FaceForward", 71 => "Reflect", 72 => "Refract", 73 => "FindILsb",
        74 => "FindSMsb", 75 => "FindUMsb", 76 => "InterpolateAtCentroid",
        77 => "InterpolateAtSample", 78 => "InterpolateAtOffset", 79 => "NMin",
        80 => "NMax", 81 => "NClamp",
        else => "Unknown",
    };
}

/// Record which GLSL.std.450 instruction had no WGSL mapping (into the
/// threadlocal detail), then return the honest error. Use at every
/// `UnsupportedExtInst` site: `return recordUnsupportedExtInst(op);`.
fn recordUnsupportedExtInst(op: u32) error{UnsupportedExtInst} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "GLSL.std.450 {s} ({d}) has no WGSL equivalent",
        .{ glslStd450Name(op), op },
    ) catch null;
    return error.UnsupportedExtInst;
}

/// Single source of truth: glslpp's internal GLSL.std.450 opcode number → WGSL
/// builtin name. Used by BOTH the main emit path and the loop-replay path so the
/// two cannot drift (they previously had divergent inline switches — the replay
/// path was missing modf/frexp/ldexp/pack*/unpack*/findILsb/findSMsb). Unmapped
/// instructions fail loud via recordUnsupportedExtInst (never a silent unknown()).
fn glslStd450WgslName(instruction: u32) error{UnsupportedExtInst}![]const u8 {
    return switch (instruction) {
        1 => "round",
        2 => "round", // RoundEven
        3 => "trunc",
        4 => "abs", // FAbs
        5 => "abs", // SAbs → abs
        6 => "sign", // FSign
        7 => "sign", // SSign → sign
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
        25 => "atan2",
        26 => "pow",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "inverseSqrt",
        33 => "determinant",
        34 => "matrixInverse",
        35 => "modf", // ModfStruct
        36 => "modf",
        37 => "min", // FMin
        38 => "min", // SMin
        39 => "min", // UMin
        40 => "max", // FMax
        41 => "max", // UMax
        42 => "max", // SMax
        43 => "clamp", // FClamp
        44 => "clamp", // UClamp
        45 => "clamp", // SClamp
        46 => "mix",
        48 => "step",
        49 => "smoothstep",
        50 => "fma",
        51 => "frexp", // FrexpStruct
        52 => "frexp",
        53 => "ldexp",
        // WGSL packing intrinsics use a different name shape than GLSL:
        //   GLSL packSnorm4x8 → WGSL pack4x8snorm (and so on).
        54 => "pack4x8snorm",
        55 => "pack4x8unorm",
        56 => "pack2x16snorm",
        57 => "pack2x16unorm",
        58 => "pack2x16float",
        60 => "unpack2x16snorm",
        61 => "unpack2x16unorm",
        62 => "unpack2x16float",
        63 => "unpack4x8snorm",
        64 => "unpack4x8unorm",
        // Geometric — glslpp numbering starts at 66.
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceForward",
        71 => "reflect",
        72 => "refract",
        73 => "findILsb",
        74 => "findSMsb",
        else => return recordUnsupportedExtInst(instruction),
    };
}

/// Options for SPIR-V → WGSL cross-compilation.
pub const WgslCompileOptions = struct {
    /// Entry point name to compile (default: "main").
    entry_point_name: []const u8 = "main",
    /// Shift all descriptor bindings by this amount. -1 remaps binding=1 → @binding(0).
    /// Negative results clamp to 0. Mirrors `HlslCompileOptions.binding_shift`.
    ///
    /// Note: WGSL's @group is derived from the binding number (group = binding/2);
    /// the shift is applied before the group derivation, so a non-trivial shift
    /// can also change @group values.
    binding_shift: i32 = 0,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    return common.getDef(module, id);
}

fn getTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    return common.getTypeOf(module, id);
}

fn isStructType(module: *const ParsedModule, type_id: u32) bool {
    const ti = common.getDef(module, type_id);
    if (ti) |inst| {
        if (inst.op == .TypeStruct) return true;
        if (inst.op == .TypePointer and inst.words.len > 3) return isStructType(module, inst.words[3]);
    }
    return false;
}

/// True when `image_type_id` resolves to an OpTypeImage flagged as a depth
/// (comparison) image — the Depth operand (word[4]) equals 1. GLSL's
/// `sampler2DShadow` and friends lower to such images. WGSL requires these to
/// be a `texture_depth_*` texture paired with a `sampler_comparison`, so both
/// resource types must follow this flag; emitting the default
/// `texture_2d<f32>` + plain `sampler` is silent-wrong (glslpp exits 0 but
/// naga rejects with "Comparison sampling mismatch"). Accepts either an
/// OpTypeImage id or an OpTypeSampledImage id (the latter is unwrapped to its
/// underlying image).
///
/// OpTypeImage layout: [op, result_id, sampled_type, dim, DEPTH, arrayed, ms, sampled, format]
fn imageTypeIsDepth(module: *const ParsedModule, image_type_id: u32) bool {
    var inst = getDef(module, image_type_id) orelse return false;
    if (inst.op == .TypeSampledImage and inst.words.len > 2) {
        inst = getDef(module, inst.words[2]) orelse return false;
    }
    if (inst.op != .TypeImage) return false;
    return inst.words.len > 4 and inst.words[4] == 1;
}

/// How a depth-compare coordinate must be reshaped for WGSL's
/// textureSampleCompare* builtins, derived from the OpTypeImage behind a
/// sampled-image value.
const DepthCompareShape = struct {
    /// Spatial coordinate component count: 2 for the 2D family, 3 for cube.
    /// glslang packs the depth reference (and, for arrayed forms, the array
    /// layer) as trailing coordinate components, but WGSL requires the spatial
    /// coordinate to be EXACTLY the texture's dimension — so it must be sliced
    /// to this many components or naga rejects it ("Image coordinate type does
    /// not match dimension").
    comps: u32,
    /// True for an arrayed depth texture (sampler2DArrayShadow,
    /// samplerCubeArrayShadow). WGSL takes the array layer as a SEPARATE integer
    /// argument right after the coordinate, not packed into it; the layer is the
    /// coordinate component just past the spatial coords (.z for 2D, .w for cube).
    arrayed: bool,
};

fn depthCompareShape(module: *const ParsedModule, sampled_image_value_id: u32) DepthCompareShape {
    const default = DepthCompareShape{ .comps = 2, .arrayed = false };
    const type_id = getTypeOf(module, sampled_image_value_id) orelse return default;
    var inst = getDef(module, type_id) orelse return default;
    if (inst.op == .TypePointer and inst.words.len > 3) {
        inst = getDef(module, inst.words[3]) orelse return default;
    }
    if (inst.op == .TypeSampledImage and inst.words.len > 2) {
        inst = getDef(module, inst.words[2]) orelse return default;
    }
    if (inst.op != .TypeImage or inst.words.len <= 3) return default;
    const comps: u32 = switch (inst.words[3]) {
        3 => 3, // Cube → vec3 coordinate
        else => 2, // 2D family → vec2 coordinate (array layer is a separate arg)
    };
    const arrayed = inst.words.len > 5 and inst.words[5] == 1;
    return .{ .comps = comps, .arrayed = arrayed };
}

/// Emit a WGSL depth-compare sample for OpImageSampleDref{Implicit,Explicit}Lod.
/// `builtin` is "textureSampleCompare" (implicit) or "textureSampleCompareLevel"
/// (explicit — WGSL drops the SPIR-V Lod operand, always sampling mip 0).
///
/// glslang packs the depth reference (and, for arrayed forms, the array layer)
/// into the coordinate, but WGSL wants the spatial coordinate sliced to exactly
/// the texture's dimension (.xy / .xyz) with the Dref taken from the separate
/// SPIR-V operand. Arrayed depth textures additionally take the layer as its own
/// rounded i32 argument right after the coordinate (the component just past the
/// spatial coords: .z for 2D, .w for cube) — matching texture_depth_2d_array /
/// texture_depth_cube_array's signature. Emitting the packed coordinate as-is,
/// or dropping the layer, is rejected by naga (or silently wrong).
fn emitDepthCompare(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    w: anytype,
    indent: u32,
    arena: std.mem.Allocator,
    inst: Instruction,
    builtin: []const u8,
) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const tex_name = names.get(inst.words[3]) orelse "tex";
    const coord = names.get(inst.words[4]) orelse "uv";
    const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
    const shape = depthCompareShape(module, inst.words[3]);
    const coord_swz: []const u8 = if (shape.comps == 3) ".xyz" else ".xy";
    try writeIndentStatic(w, indent);
    if (shape.arrayed) {
        const layer_comp: []const u8 = if (shape.comps == 3) ".w" else ".z";
        try w.print("let {s}: {s} = {s}({s}, {s}_sampler, {s}{s}, i32(round({s}{s})), {s});\n", .{ result_name, rt, builtin, tex_name, tex_name, coord, coord_swz, coord, layer_comp, dref });
    } else {
        try w.print("let {s}: {s} = {s}({s}, {s}_sampler, {s}{s}, {s});\n", .{ result_name, rt, builtin, tex_name, tex_name, coord, coord_swz, dref });
    }
}

// Strict WGSL keywords + reserved words from https://www.w3.org/TR/WGSL/#reserved-words
// plus the commonly-emitted predeclared type / address-space names that
// callers also can't legally use as identifiers. Reserved words include `ref`,
// which is what the GL_EXT_buffer_reference fixture trips over.
const wgsl_reserved_words = std.StaticStringMap(void).initComptime(.{
    // Keywords (§ Keyword Summary)
    .{ "alias", {} },         .{ "break", {} },         .{ "case", {} },
    .{ "const", {} },         .{ "const_assert", {} },  .{ "continue", {} },
    .{ "continuing", {} },    .{ "default", {} },       .{ "diagnostic", {} },
    .{ "discard", {} },       .{ "else", {} },          .{ "enable", {} },
    .{ "false", {} },         .{ "fn", {} },            .{ "for", {} },
    .{ "if", {} },            .{ "let", {} },           .{ "loop", {} },
    .{ "override", {} },      .{ "requires", {} },      .{ "return", {} },
    .{ "struct", {} },        .{ "switch", {} },        .{ "true", {} },
    .{ "var", {} },           .{ "while", {} },
    // Reserved words (§ Reserved Words)
    .{ "NULL", {} },          .{ "Self", {} },          .{ "abstract", {} },
    .{ "active", {} },        .{ "alignas", {} },       .{ "alignof", {} },
    .{ "as", {} },            .{ "asm", {} },           .{ "asm_fragment", {} },
    .{ "async", {} },         .{ "attribute", {} },     .{ "auto", {} },
    .{ "await", {} },         .{ "become", {} },        .{ "binding_array", {} },
    .{ "cast", {} },          .{ "catch", {} },         .{ "class", {} },
    .{ "co_await", {} },      .{ "co_return", {} },     .{ "co_yield", {} },
    .{ "coherent", {} },      .{ "column_major", {} },  .{ "common", {} },
    .{ "compile", {} },       .{ "compile_fragment", {} }, .{ "concept", {} },
    .{ "const_cast", {} },    .{ "consteval", {} },     .{ "constexpr", {} },
    .{ "constinit", {} },     .{ "crate", {} },         .{ "debugger", {} },
    .{ "decltype", {} },      .{ "delete", {} },        .{ "demote", {} },
    .{ "demote_to_helper", {} }, .{ "do", {} },         .{ "dynamic_cast", {} },
    .{ "enum", {} },          .{ "explicit", {} },      .{ "export", {} },
    .{ "extends", {} },       .{ "extern", {} },        .{ "external", {} },
    .{ "fallthrough", {} },   .{ "filter", {} },        .{ "final", {} },
    .{ "finally", {} },       .{ "friend", {} },        .{ "from", {} },
    .{ "fxgroup", {} },       .{ "get", {} },           .{ "goto", {} },
    .{ "groupshared", {} },   .{ "highp", {} },         .{ "impl", {} },
    .{ "implements", {} },    .{ "import", {} },        .{ "inline", {} },
    .{ "instanceof", {} },    .{ "interface", {} },     .{ "layout", {} },
    .{ "lowp", {} },          .{ "macro", {} },         .{ "macro_rules", {} },
    .{ "match", {} },         .{ "mediump", {} },       .{ "meta", {} },
    .{ "mod", {} },           .{ "module", {} },        .{ "move", {} },
    .{ "mut", {} },           .{ "mutable", {} },       .{ "namespace", {} },
    .{ "new", {} },           .{ "nil", {} },           .{ "noexcept", {} },
    .{ "noinline", {} },      .{ "nointerpolation", {} }, .{ "non_coherent", {} },
    .{ "noncoherent", {} },   .{ "noperspective", {} }, .{ "null", {} },
    .{ "nullptr", {} },       .{ "of", {} },            .{ "operator", {} },
    .{ "package", {} },       .{ "packoffset", {} },    .{ "partition", {} },
    .{ "pass", {} },          .{ "patch", {} },         .{ "pixelfragment", {} },
    .{ "precise", {} },       .{ "precision", {} },     .{ "premerge", {} },
    .{ "priv", {} },          .{ "protected", {} },     .{ "pub", {} },
    .{ "public", {} },        .{ "readonly", {} },      .{ "ref", {} },
    .{ "regardless", {} },    .{ "register", {} },      .{ "reinterpret_cast", {} },
    .{ "require", {} },       .{ "resource", {} },      .{ "restrict", {} },
    .{ "self", {} },          .{ "set", {} },           .{ "shared", {} },
    .{ "sizeof", {} },        .{ "smooth", {} },        .{ "snorm", {} },
    .{ "static", {} },        .{ "static_assert", {} }, .{ "static_cast", {} },
    .{ "std", {} },           .{ "subroutine", {} },    .{ "super", {} },
    .{ "target", {} },        .{ "template", {} },      .{ "this", {} },
    .{ "thread_local", {} },  .{ "throw", {} },         .{ "trait", {} },
    .{ "try", {} },           .{ "type", {} },          .{ "typedef", {} },
    .{ "typeid", {} },        .{ "typename", {} },      .{ "typeof", {} },
    .{ "union", {} },         .{ "unless", {} },        .{ "unorm", {} },
    .{ "unsafe", {} },        .{ "unsized", {} },       .{ "use", {} },
    .{ "using", {} },         .{ "varying", {} },       .{ "virtual", {} },
    .{ "volatile", {} },      .{ "wgsl", {} },          .{ "where", {} },
    .{ "with", {} },          .{ "writeonly", {} },     .{ "yield", {} },
    // Predeclared scalar / address-space / type names that are also illegal
    // as identifiers — kept from the previous (pre-spec) list for back-compat.
    .{ "array", {} },         .{ "atomic", {} },        .{ "bool", {} },
    .{ "f16", {} },           .{ "f32", {} },           .{ "function", {} },
    .{ "i32", {} },           .{ "mat2x2", {} },        .{ "mat2x3", {} },
    .{ "mat2x4", {} },        .{ "mat3x2", {} },        .{ "mat3x3", {} },
    .{ "mat3x4", {} },        .{ "mat4x2", {} },        .{ "mat4x3", {} },
    .{ "mat4x4", {} },        .{ "private", {} },       .{ "ptr", {} },
    .{ "storage", {} },       .{ "u32", {} },           .{ "uniform", {} },
    .{ "vec2", {} },          .{ "vec3", {} },          .{ "vec4", {} },
    .{ "workgroup", {} },
    // Predeclared texture / sampler types (§ Texture Types, § Sampler Types).
    // Not strictly reserved by the spec, but shadowing them produces output
    // that confuses naga's diagnostics and may break under future revisions.
    .{ "sampler", {} },                  .{ "sampler_comparison", {} },
    .{ "texture_1d", {} },               .{ "texture_2d", {} },
    .{ "texture_2d_array", {} },         .{ "texture_3d", {} },
    .{ "texture_cube", {} },             .{ "texture_cube_array", {} },
    .{ "texture_multisampled_2d", {} },  .{ "texture_depth_2d", {} },
    .{ "texture_depth_2d_array", {} },   .{ "texture_depth_cube", {} },
    .{ "texture_depth_cube_array", {} }, .{ "texture_depth_multisampled_2d", {} },
    .{ "texture_storage_1d", {} },       .{ "texture_storage_2d", {} },
    .{ "texture_storage_2d_array", {} }, .{ "texture_storage_3d", {} },
    .{ "texture_external", {} },
});

fn isWgslKeyword(name: []const u8) bool {
    return wgsl_reserved_words.has(name);
}

/// Marks a struct member as the target of WGSL atomic ops.
/// `scalar` → wrap whole field in `atomic<T>` (e.g. `counter: atomic<u32>`)
/// `array_element` → wrap element type (e.g. `data: array<atomic<u32>>`)
const AtomicFieldKind = enum { scalar, array_element };

const AtomicFieldKey = struct { struct_id: u32, member_idx: u32 };
const AtomicFieldMap = std.AutoHashMap(AtomicFieldKey, AtomicFieldKind);

fn getMemberName(module: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    const raw = common.commonGetMemberName(module.instructions, struct_id, member_idx, buf, "_");
    if (!isWgslKeyword(raw)) return raw;
    // Keyword conflict: append `_` to the existing buffer.
    // commonGetMemberName caps raw.len at buf.len - 1 (= 31), so the
    // suffix always fits in buf[raw.len]. The bounds check is a safety net
    // for future relaxations of that cap.
    if (raw.len + 1 <= buf.len) {
        buf[raw.len] = '_';
        return buf[0 .. raw.len + 1];
    }
    return raw;
}

fn getArraySuffix(module: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    return common.commonGetArraySuffix(module.instructions, module.id_defs, ptr_type_id, false);
}

fn emitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap) !void {
    const inst = getDef(module, root_type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            try emitOneStructForwardDecl(module, names, root_type_id, w, alloc, emitted, emitted_names, atomic_fields);
        },
        .TypePointer => if (inst.words.len > 3) try emitStructForwardDecls(module, names, inst.words[3], w, alloc, emitted, emitted_names, atomic_fields),
        .TypeArray => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields),
        else => {},
    }
}

fn emitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap) !void {
    const inst = getDef(module, type_id) orelse return;
    if (inst.op != .TypeStruct) return;
    if (inst.words.len > 2) {
        for (inst.words[2..]) |mt_id| {
            // Recurse into the member type, unwrapping wrapper types until we
            // reach the underlying struct. Without the TypePointer unwrap,
            // GL_EXT_buffer_reference members — encoded in SPIR-V as
            // TypePointer to TypeStruct — never emit the pointee struct, and
            // naga rejects the WGSL with
            // `no definition in scope for identifier: <pointee>`.
            //
            // Depth cap of 8 protects against pathological cycles in
            // malformed SPIR-V. Realistic wrapper chains are 1–3 deep
            // (e.g. `TypePointer → TypeRuntimeArray → TypeStruct`); hitting
            // 8 means the input is adversarial. On overflow we silently
            // skip emitting the pointee, which re-introduces the
            // FloatRef-class diagnostic from naga — informative enough to
            // diagnose without us adding error-handling at this layer.
            var cur_id = mt_id;
            var depth: u32 = 0;
            while (depth < 8) : (depth += 1) {
                const cur_inst = getDef(module, cur_id) orelse break;
                switch (cur_inst.op) {
                    .TypeStruct => {
                        try emitOneStructForwardDecl(module, names, cur_id, w, alloc, emitted, emitted_names, atomic_fields);
                        break;
                    },
                    .TypePointer => {
                        if (cur_inst.words.len > 3) cur_id = cur_inst.words[3] else break;
                    },
                    .TypeArray, .TypeRuntimeArray, .TypeMatrix, .TypeVector => {
                        if (cur_inst.words.len > 2) cur_id = cur_inst.words[2] else break;
                    },
                    else => break,
                }
            }
        }
    }
    if (emitted.get(type_id) != null) return;
    const sname = names.get(type_id) orelse "Struct";
    if (emitted_names.get(sname) != null) return;
    emitted.put(type_id, {}) catch return;
    try emitted_names.put(sname, {});
    try w.print("struct {s} {{\n", .{sname});
    for (inst.words[2..], 0..) |mt_id, mi| {
        const mti = getDef(module, mt_id);
        var mname_buf: [32]u8 = undefined;
        const mname = getMemberName(module, type_id, @as(u32, @intCast(mi)), &mname_buf);
        const atomic_kind: ?AtomicFieldKind = atomic_fields.get(.{ .struct_id = type_id, .member_idx = @intCast(mi) });

        // A row_major NON-square matrix needs swapped declared dimensions in
        // WGSL (which has no row_major feature) to read back the logical matrix
        // via transpose; not yet implemented. Fail loudly instead of emitting a
        // member that the transposed read silently mis-shapes. Square row_major
        // matrices are fully handled by transposing reads (findRowMajorMatrix).
        if (memberIsRowMajor(module, type_id, @intCast(mi))) {
            const elem_tid: ?u32 = if (mti) |mi2| blk: {
                if (mi2.op == .TypeMatrix) break :blk mt_id;
                if (mi2.op == .TypeArray and mi2.words.len > 2) break :blk mi2.words[2];
                break :blk null;
            } else null;
            if (elem_tid) |etid| {
                const et = getDef(module, etid);
                if (et != null and et.?.op == .TypeMatrix and !matrixIsSquare(module, etid))
                    return error.UnsupportedRowMajorMatrix;
            }
        }

        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const et = try wgslType(module, mi2.words[2], names, alloc);
                const li = getDef(module, mi2.words[3]);
                const lv: u32 = if (li) |l| l.words[3] else 1;
                if (atomic_kind == .array_element) {
                    try w.print("    {s}: array<atomic<{s}>, {d}>,\n", .{ mname, et, lv });
                } else {
                    try w.print("    {s}: array<{s}, {d}>,\n", .{ mname, et, lv });
                }
                continue;
            }
            if (mi2.op == .TypeRuntimeArray and mi2.words.len > 2 and atomic_kind == .array_element) {
                const et = try wgslType(module, mi2.words[2], names, alloc);
                try w.print("    {s}: array<atomic<{s}>>,\n", .{ mname, et });
                continue;
            }
        }
        const mt = try wgslType(module, mt_id, names, alloc);
        if (atomic_kind == .scalar) {
            try w.print("    {s}: atomic<{s}>,\n", .{ mname, mt });
        } else {
            try w.print("    {s}: {s},\n", .{ mname, mt });
        }
    }
    try w.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// WGSL type resolution
// ---------------------------------------------------------------------------

fn writeIndentStatic(w: anytype, depth: u32) !void {
    var d: u32 = 0;
    while (d < depth) : (d += 1) try w.writeAll("    ");
}

fn wgslType(module: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, type_id) orelse return "vec4f";
    return switch (inst.op) {
        .TypeVoid => "void",
        .TypeBool => "bool",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "i32" else "u32",
        .TypeFloat => "f32",
        .TypeVector => {
            const s = try wgslType(module, inst.words[2], names, alloc);
            const c = inst.words[3];
            if (std.mem.eql(u8, s, "f32")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "f32", "vec2f", "vec3f", "vec4f" })[c];
            } else if (std.mem.eql(u8, s, "i32")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "i32", "vec2i", "vec3i", "vec4i" })[c];
            } else if (std.mem.eql(u8, s, "u32")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "u32", "vec2u", "vec3u", "vec4u" })[c];
            } else if (std.mem.eql(u8, s, "bool")) {
                if (c >= 1 and c <= 4) return ([_][]const u8{ "", "bool", "vec2<bool>", "vec3<bool>", "vec4<bool>" })[c];
            }
            return std.fmt.allocPrint(alloc, "vec{d}<{s}>", .{ c, s });
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const ct = getDef(module, inst.words[2]);
            const rows: u32 = if (ct) |c| c.words[3] else cols;
            return std.fmt.allocPrint(alloc, "mat{d}x{d}f", .{ cols, rows });
        },
        .TypeArray => {
            const elem_type = try wgslType(module, inst.words[2], names, alloc);
            const len_id = inst.words[3];
            const len_def = getDef(module, len_id);
            if (len_def) |ld| {
                if (ld.op == .Constant and ld.words.len > 3) {
                    return std.fmt.allocPrint(alloc, "array<{s}, {d}>", .{ elem_type, ld.words[3] });
                }
            }
            return std.fmt.allocPrint(alloc, "array<{s}>", .{elem_type});
        },
        .TypeRuntimeArray => {
            const elem_type = try wgslType(module, inst.words[2], names, alloc);
            return std.fmt.allocPrint(alloc, "array<{s}>", .{elem_type});
        },
        .TypePointer => if (inst.words.len > 3) try wgslType(module, inst.words[3], names, alloc) else "vec4f",
        .TypeStruct => names.get(type_id) orelse "Struct",
        .TypeSampler => "sampler",
        .TypeImage => blk: {
            // texture_2d<f32>, texture_1d<f32>, texture_3d<f32>, texture_cube<f32>, etc.
            // OpTypeImage layout: [header, result_id, sampled_type, dim, depth, arrayed, ms, sampled, format]
            const dim = if (inst.words.len > 3) inst.words[3] else 1;
            const sampled_type_id = inst.words[2];
            const st = try wgslType(module, sampled_type_id, names, alloc);
            const tex_type: []const u8 = switch (dim) {
                0 => "texture_1d",
                1 => "texture_2d",
                2 => "texture_3d",
                3 => "texture_cube",
                4 => "texture_2d_array",
                5 => "texture_buffer",
                6 => "texture_2d",
                else => "texture_2d",
            };
            // Check if multisampled (words[6]) or storage image (words[7] != 0)
            const is_ms = if (inst.words.len > 6) inst.words[6] == 1 else false;
            const access_qualifier: u32 = if (inst.words.len > 7) inst.words[7] else 0;
            const is_storage = access_qualifier == 2; // Only ReadWrite is storage with both load+store
            // WriteOnly (1) images are also storage but we handle them with regular textures
            // Depth (comparison) image — the Depth operand (word[4]) is 1, e.g.
            // GLSL sampler2DShadow. WGSL depth textures take NO <T> sampled-type
            // parameter (they are implicitly f32) and must pair with a
            // sampler_comparison; see imageTypeIsDepth for why this matters.
            const is_depth = inst.words.len > 4 and inst.words[4] == 1;
            if (is_depth) {
                // Array-ness comes from the Arrayed operand (word[5]), not `dim`;
                // `dim` only selects cube vs 2D. WGSL has no multisampled depth
                // array type, so a (rare, GLSL-inexpressible) depth+MS+arrayed
                // image falls back to the non-arrayed multisampled form.
                const arrayed = inst.words.len > 5 and inst.words[5] == 1;
                if (is_ms) break :blk "texture_depth_multisampled_2d";
                break :blk switch (dim) {
                    3 => if (arrayed) "texture_depth_cube_array" else "texture_depth_cube",
                    else => if (arrayed) "texture_depth_2d_array" else "texture_depth_2d",
                };
            } else if (is_storage) {
                const access_mode: []const u8 = switch (access_qualifier) {
                    1 => "write",
                    2 => "read_write",
                    else => "write",
                };
                const format: []const u8 = switch (dim) {
                    1 => try std.fmt.allocPrint(alloc, "texture_storage_2d<rgba8unorm, {s}>", .{access_mode}),
                    2 => try std.fmt.allocPrint(alloc, "texture_storage_3d<rgba8unorm, {s}>", .{access_mode}),
                    else => try std.fmt.allocPrint(alloc, "texture_storage_2d<rgba8unorm, {s}>", .{access_mode}),
                };
                break :blk format;
            } else if (is_ms) {
                break :blk std.fmt.allocPrint(alloc, "{s}_multisampled<{s}>", .{ tex_type, st }) catch "texture_2d<f32>";
            } else {
                break :blk std.fmt.allocPrint(alloc, "{s}<{s}>", .{ tex_type, st }) catch "texture_2d<f32>";
            }
        },
        .TypeSampledImage => if (inst.words.len > 2) try wgslType(module, inst.words[2], names, alloc) else "texture_2d<f32>",
        else => "vec4f",
    };
}

// ---------------------------------------------------------------------------
// Decoration helpers
// ---------------------------------------------------------------------------

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

fn collectDecorations(alloc: std.mem.Allocator, module: *const ParsedModule, decorations: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    try common.collectDecorations(alloc, module, decorations);
}

fn collectNames(alloc: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    common.collectNames(alloc, module, names);

    // Post-process: rename OpName-sourced identifiers that collide with WGSL
    // reserved words. Struct member names (OpMemberName) are handled
    // separately by getMemberName.
    //
    // Critical: OpName can target a constant id, and common.collectNames
    // also overwrites names[constant_id] with the constant's *literal text*
    // ("true", "false", "1.0", composite-constructor string, ...). Because
    // OpName precedes constants in the SPIR-V binary layout, the literal
    // wins in the map. Renaming naively would corrupt the literal — e.g.
    // `const bool ENABLED = true;` would emit `if (true_) { ... }`, which
    // naga rejects as an unknown identifier. glslpp's own frontend only
    // attaches OpName to globals/functions/spec-constants, but external
    // SPIR-V (glslang, hand-crafted) freely names plain constants, so the
    // skip is required for `spirvToWGSL` as a public API.
    for (module.instructions) |inst| {
        if (inst.op != .Name or inst.words.len < 3) continue;
        const id = inst.words[1];
        const target = getDef(module, id) orelse continue;
        switch (target.op) {
            .Constant, .ConstantTrue, .ConstantFalse, .ConstantComposite,
            .SpecConstant, .SpecConstantTrue, .SpecConstantFalse,
            .SpecConstantComposite, .SpecConstantOp,
            => continue,
            else => {},
        }
        const current = names.get(id) orelse continue;
        if (!isWgslKeyword(current)) continue;
        const renamed = std.fmt.allocPrint(alloc, "{s}_", .{current}) catch continue;
        if (names.fetchPut(id, renamed) catch null) |old| alloc.free(old.value);
    }

    // Post-process: simplify uniform vector constructors like vec3f(0.0, 0.0, 0.0) → vec3f(0.0)
    var it = names.iterator();
    var replacements = std.ArrayList(struct { key: u32, val: []const u8 }).initCapacity(alloc, 16) catch return;
    defer replacements.deinit(alloc);
    while (it.next()) |e| {
        const name = e.value_ptr.*;
        // Match vecNf(val, val, ..., val) where all values are identical
        if (std.mem.startsWith(u8, name, "float") or std.mem.startsWith(u8, name, "vec")) {
            // Find the opening paren
            if (std.mem.indexOfScalar(u8, name, '(')) |paren_pos| {
                const args = name[paren_pos + 1 .. name.len - 1]; // strip parens
                // Split by ", " and check if all parts are equal
                var parts = std.mem.splitSequence(u8, args, ", ");
                var first: ?[]const u8 = null;
                var all_same = true;
                var count: u32 = 0;
                while (parts.next()) |part| {
                    if (first == null) {
                        first = part;
                    } else if (!std.mem.eql(u8, part, first.?)) {
                        all_same = false;
                        break;
                    }
                    count += 1;
                }
                if (all_same and count >= 2 and first != null) {
                    // Replace with shorter form: vec3f(val) instead of vec3f(val, val, val)
                    const prefix = name[0 .. paren_pos + 1];
                    const new_name = std.fmt.allocPrint(alloc, "{s}{s})", .{ prefix, first.? }) catch continue;
                    replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
                }
            }
        }
    }
    for (replacements.items) |r| {
        if (names.fetchPut(r.key, r.val) catch null) |old| alloc.free(old.value);
    }
}

// ---------------------------------------------------------------------------
// Access expression builder
// ---------------------------------------------------------------------------

/// True if struct member `member_index` of `struct_id` carries the SPIR-V
/// RowMajor decoration (4). WGSL has no row_major feature and is column-indexed,
/// so a row-major matrix's std140 bytes are read as the TRANSPOSE of the logical
/// matrix — every read must be transposed back (see `findRowMajorMatrix`).
fn memberIsRowMajor(module: *const ParsedModule, struct_id: u32, member_index: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 4 and
            inst.words[1] == struct_id and inst.words[2] == member_index)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .row_major) return true;
        }
    }
    return false;
}

const RowMajorAccess = struct { boundary: usize, matrix_tid: u32 };

/// Return where a row-major matrix VALUE is produced in `indices`, so the read
/// can be wrapped in `transpose(...)` (`indices[0..boundary+1]` produces the
/// matrix; `indices[boundary+1..]` is the column/element tail). A row-major
/// matrix is stored transposed in WGSL (which is column-major with no row_major
/// feature), so BOTH a whole-matrix load (feeding mul — WGSL has no keyword to
/// fix storage) and a column read must transpose. The matrix may be a direct
/// struct member OR a row-major member's array element (`a.mats[k]`). Non-square
/// row-major matrices need swapped declared DIMENSIONS (rejected at struct
/// emission); only square ones reach here. Generalizes the MSL backend's helper
/// (which handles only direct members) to array-of-matrix members.
fn findRowMajorMatrix(module: *const ParsedModule, base_id: u32, indices: []const u32) ?RowMajorAccess {
    var cur_type: ?u32 = resolvePointee(module, base_id);
    var member_row_major = false; // did the enclosing struct member carry RowMajor?
    for (indices, 0..) |index_id, i| {
        const tid = cur_type orelse return null;
        const ti = getDef(module, tid) orelse return null;
        if (ti.op == .TypeStruct) {
            const def = getDef(module, index_id) orelse return null;
            if (def.op != .Constant or def.words.len <= 3) return null;
            const val = def.words[3];
            if (val + 2 >= ti.words.len) return null;
            member_row_major = memberIsRowMajor(module, tid, val);
            const member_tid = ti.words[val + 2];
            const mdef = getDef(module, member_tid);
            if (mdef != null and mdef.?.op == .TypeMatrix and member_row_major) {
                if (matrixIsSquare(module, member_tid)) return .{ .boundary = i, .matrix_tid = member_tid };
                return null; // non-square: handled by honest error at declaration
            }
            cur_type = member_tid;
        } else if (ti.op == .TypeArray) {
            const elem = ti.words[2];
            const edef = getDef(module, elem);
            if (edef != null and edef.?.op == .TypeMatrix and member_row_major) {
                if (matrixIsSquare(module, elem)) return .{ .boundary = i, .matrix_tid = elem };
                return null; // non-square: handled at declaration
            }
            cur_type = elem;
        } else if (ti.op == .TypeVector or ti.op == .TypeMatrix) {
            cur_type = ti.words[2];
        } else {
            return null;
        }
    }
    return null;
}

/// True if `type_id` is a SQUARE matrix (column count == row count).
fn matrixIsSquare(module: *const ParsedModule, type_id: u32) bool {
    const mt = getDef(module, type_id) orelse return false;
    if (mt.op != .TypeMatrix) return false;
    const colvec = getDef(module, mt.words[2]) orelse return false;
    if (colvec.op != .TypeVector) return false;
    return mt.words[3] == colvec.words[3];
}

/// Emit the access-chain indices that come AFTER a transposed row-major matrix:
/// a matrix-column index becomes `[col]` on the transposed value, and a
/// vector-element index becomes a `.xyzw` swizzle.
fn appendMatrixTail(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), matrix_tid: u32, indices: []const u32, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var cur_type: ?u32 = matrix_tid;
    for (indices) |index_id| {
        const def = getDef(module, index_id);
        const ti = if (cur_type) |t| getDef(module, t) else null;
        if (def != null and def.?.op == .Constant and def.?.words.len > 3) {
            const val = def.?.words[3];
            if (ti != null and ti.?.op == .TypeVector) {
                try buf.appendSlice(alloc, switch (val) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" });
                cur_type = ti.?.words[2];
            } else {
                try buf.print(alloc, "[{d}]", .{val});
                cur_type = if (ti != null and (ti.?.op == .TypeMatrix or ti.?.op == .TypeArray)) ti.?.words[2] else null;
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            cur_type = if (ti != null and (ti.?.op == .TypeMatrix or ti.?.op == .TypeArray)) ti.?.words[2] else null;
        }
    }
}

/// Build an access-chain expression. A read that traverses a row-major matrix
/// member is wrapped in `transpose(...)`: WGSL stores the row-major bytes as the
/// transpose of the logical matrix, so transposing reconstructs it (matching the
/// MSL backend). Whole-matrix loads ARE transposed too (WGSL has no row_major
/// keyword to fix storage, so even `a.m` for `mul` reads Mᵀ).
fn buildAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    if (indices.len != 0) {
        if (findRowMajorMatrix(module, base_id, indices)) |hit| {
            var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return error.OutOfMemory;
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, "transpose(");
            const inner = try buildAccessExprPlain(module, names, base_id, indices[0 .. hit.boundary + 1], alloc);
            defer alloc.free(inner);
            try buf.appendSlice(alloc, inner);
            try buf.appendSlice(alloc, ")");
            try appendMatrixTail(module, names, hit.matrix_tid, indices[hit.boundary + 1 ..], &buf, alloc);
            return buf.toOwnedSlice(alloc);
        }
    }
    return buildAccessExprPlain(module, names, base_id, indices, alloc);
}

fn buildAccessExprPlain(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) return try alloc.dupe(u8, base_name);

    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_name);

    var current_type_id: ?u32 = resolvePointee(module, base_id);

    for (indices) |index_id| {
        const idx_inst = getDef(module, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (current_type_id) |tid| blk: {
                    const ti = getDef(module, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;
                const is_struct = if (current_type_id) |tid| blk: {
                    const ti = getDef(module, tid);
                    break :blk ti != null and ti.?.op == .TypeStruct;
                } else false;

                if (is_vector) {
                    try buf.appendSlice(alloc, switch (val) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                    if (current_type_id) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| current_type_id = tinst.words[2];
                    }
                } else if (is_struct) {
                    var mname_buf: [32]u8 = undefined;
                    const mname = getMemberName(module, current_type_id.?, val, &mname_buf);
                    try buf.print(alloc, ".{s}", .{mname});
                    if (current_type_id) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (val + 2 < tinst.words.len) current_type_id = tinst.words[val + 2];
                        }
                    }
                } else {
                    try buf.print(alloc, "[{d}]", .{val});
                    if (current_type_id) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| current_type_id = tinst.words[2];
                    }
                }
            } else {
                const idx_name = names.get(index_id) orelse "i";
                try buf.print(alloc, "[{s}]", .{idx_name});
                if (current_type_id) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| current_type_id = tinst.words[2];
                }
            }
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Try to resolve a constant expression to a WGSL literal string
fn resolveConstantExpr(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), id: u32, arena: std.mem.Allocator) ?[]const u8 {
    _ = names;
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .Constant => {
            if (inst.words.len < 4) return null;
            const val = inst.words[3];
            const type_id = inst.words[1];
            const type_inst = common.getDef(module, type_id) orelse return null;
            if (type_inst.op == .TypeFloat) {
                const bits: u32 = if (type_inst.words.len > 2) type_inst.words[2] else 32;
                if (bits == 32) {
                    const f: f32 = @bitCast(val);
                    var buf = std.ArrayList(u8).initCapacity(arena, 32) catch return null;
                    if (f == @floor(f) and @abs(f) < 1e6) {
                        buf.print(arena, "{d}.0", .{f}) catch return null;
                    } else {
                        buf.print(arena, "{d}", .{f}) catch return null;
                    }
                    return buf.toOwnedSlice(arena) catch return null;
                }
            } else if (type_inst.op == .TypeInt) {
                const is_signed = type_inst.words.len > 3 and type_inst.words[3] == 1;
                if (is_signed) {
                    const sv: i32 = @bitCast(val);
                    var buf = std.ArrayList(u8).initCapacity(arena, 16) catch return null;
                    buf.print(arena, "{d}", .{sv}) catch return null;
                    return buf.toOwnedSlice(arena) catch return null;
                } else {
                    var buf = std.ArrayList(u8).initCapacity(arena, 16) catch return null;
                    buf.print(arena, "{d}u", .{val}) catch return null;
                    return buf.toOwnedSlice(arena) catch return null;
                }
            }
        },
        else => {},
    }
    return null;
}

fn resolvePointee(module: *const ParsedModule, id: u32) ?u32 {
    // First try direct TypePointer
    if (common.resolvePointeeType(module, id)) |pt| return pt;
    // Try resolving through Variable → TypePointer → pointee
    const inst = common.getDef(module, id) orelse return null;
    if (inst.op == .Variable and inst.words.len > 1) {
        return common.resolvePointeeType(module, inst.words[1]);
    }
    return null;
}

/// Scan the module for OpAtomic* ops and record which SSBO struct members are
/// their targets. The result feeds struct emission so that those fields are
/// wrapped in `atomic<T>` (or `array<atomic<T>>` for atomic ops on array
/// elements). Walks the OpAccessChain feeding each atomic op, tracking the
/// type at each index. The deepest struct-member access along the chain is the
/// field to mark; any array/vector indices that follow it indicate
/// array-element atomics.
fn collectAtomicFields(module: *const ParsedModule, out: *AtomicFieldMap) !void {
    for (module.instructions) |inst| {
        const is_atomic = switch (inst.op) {
            .AtomicIAdd, .AtomicISub, .AtomicAnd, .AtomicOr, .AtomicXor,
            .AtomicUMin, .AtomicSMin, .AtomicUMax, .AtomicSMax,
            .AtomicFAddEXT, .AtomicExchange, .AtomicCompareExchange,
            => true,
            else => false,
        };
        if (!is_atomic) continue;
        if (inst.words.len < 4) continue;
        const ptr_id = inst.words[3];
        const ptr_inst = common.getDef(module, ptr_id) orelse continue;
        if (ptr_inst.op != .AccessChain) continue;
        if (ptr_inst.words.len < 5) continue;
        const base_id = ptr_inst.words[3];

        var current_type_id: ?u32 = resolvePointee(module, base_id);
        var last_struct_id: ?u32 = null;
        var last_member_idx: u32 = 0;
        var indices_after_last_struct: u32 = 0;

        for (ptr_inst.words[4..]) |index_id| {
            const tid = current_type_id orelse break;
            const ti = common.getDef(module, tid) orelse break;
            switch (ti.op) {
                .TypeStruct => {
                    const idx_inst = common.getDef(module, index_id) orelse break;
                    if (idx_inst.op != .Constant or idx_inst.words.len < 4) break;
                    const mi = idx_inst.words[3];
                    last_struct_id = tid;
                    last_member_idx = mi;
                    indices_after_last_struct = 0;
                    if (mi + 2 < ti.words.len) current_type_id = ti.words[mi + 2] else current_type_id = null;
                },
                .TypeArray, .TypeRuntimeArray, .TypeVector, .TypeMatrix => {
                    indices_after_last_struct += 1;
                    if (ti.words.len > 2) current_type_id = ti.words[2] else current_type_id = null;
                },
                else => break,
            }
        }

        if (last_struct_id) |sid| {
            const kind: AtomicFieldKind = if (indices_after_last_struct == 0) .scalar else .array_element;
            try out.put(.{ .struct_id = sid, .member_idx = last_member_idx }, kind);
        }
    }
}

/// Resolve the value type of an ID by tracing its defining instruction.
fn resolveTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .Variable => {
            if (inst.words.len > 1) return common.resolvePointeeType(module, inst.words[1]);
            return null;
        },
        .Load, .CopyObject, .CompositeConstruct, .CompositeInsert,
        .FunctionCall, .Phi, .Select, .CopyLogical, .FunctionParameter,
        .Undef,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast,
        .VectorShuffle, .CompositeExtract, .VectorTimesScalar,
        .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector,
        .MatrixTimesMatrix, .OuterProduct, .Transpose, .ImageSampleImplicitLod,
        .ImageSampleExplicitLod, .ImageFetch, .ImageRead,
        .FNegate, .SNegate, .Not, .LogicalNot,
        .ExtInst,
        .FAdd, .FSub, .FMul, .FDiv, .FRem, .FMod,
        .IAdd, .ISub, .IMul, .SDiv, .UDiv, .SMod, .UMod,
        .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical,
        .BitwiseAnd, .BitwiseOr, .BitwiseXor,
        .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual,
        .FOrdEqual, .FOrdNotEqual,
        .LogicalAnd, .LogicalOr,
        => {
            // words[1] is result type (may be pointer)
            if (inst.words.len > 1) {
                const ti = common.getDef(module, inst.words[1]);
                if (ti) |tinst| {
                    if (tinst.op == .TypePointer and tinst.words.len > 3) return tinst.words[3];
                    return inst.words[1]; // the type ID itself
                }
            }
            return null;
        },
        .AccessChain => {
            // Type of AccessChain result is a pointer to the element type
            // We need the pointee, not the pointer
            if (inst.words.len > 1) {
                const ti = common.getDef(module, inst.words[1]);
                if (ti) |tinst| {
                    if (tinst.op == .TypePointer and tinst.words.len > 3) return tinst.words[3];
                    return inst.words[1];
                }
            }
            return null;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn spirvToWGSL(alloc: std.mem.Allocator, spirv_words: []const u32, options: WgslCompileOptions) ![]const u8 {
    last_error_detail = null; // clear any detail from a prior compile on this thread
    var module = try common.parseModule(alloc, spirv_words);
    defer module.deinit(alloc);

    // Override entry point if requested
    if (!std.mem.eql(u8, options.entry_point_name, "main")) {
        if (common.findEntryPoint(&module, options.entry_point_name)) |ep_id| {
            module.entry_point_id = ep_id;
        } else return error.EntryPointNotFound;
    }

    var names = std.AutoHashMap(u32, []const u8).init(alloc);
    defer {
        var it = names.iterator();
        while (it.next()) |e| alloc.free(e.value_ptr.*);
        names.deinit();
    }
    collectNames(alloc, &module, &names);

    // Post-process GLSL-style names to WGSL-style
    {
        var it = names.iterator();
        var replacements = std.ArrayList(struct { key: u32, val: []const u8 }).initCapacity(alloc, 16) catch return error.OutOfMemory;
        defer replacements.deinit(alloc);
        while (it.next()) |e| {
            const name = e.value_ptr.*;
            // Replace float2(...) → vec2f(...), float3(...) → vec3f(...), float4(...) → vec4f(...)
            // Handle both leading and embedded cases (e.g., Light(float3(...), 0.5))
            if (std.mem.indexOf(u8, name, "float2(") != null or
                std.mem.indexOf(u8, name, "float3(") != null or
                std.mem.indexOf(u8, name, "float4(") != null or
                std.mem.indexOf(u8, name, "int2(") != null or
                std.mem.indexOf(u8, name, "int3(") != null or
                std.mem.indexOf(u8, name, "int4(") != null)
            {
                var new_name = name;
                var allocated = false;
                const subs = [_]struct { from: []const u8, to: []const u8 }{
                    .{ .from = "float2(", .to = "vec2f(" },
                    .{ .from = "float3(", .to = "vec3f(" },
                    .{ .from = "float4(", .to = "vec4f(" },
                    .{ .from = "int2(", .to = "vec2i(" },
                    .{ .from = "int3(", .to = "vec3i(" },
                    .{ .from = "int4(", .to = "vec4i(" },
                };
                for (subs) |sub| {
                    while (std.mem.indexOf(u8, new_name, sub.from)) |pos| {
                        const replacement = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
                            new_name[0..pos], sub.to, new_name[pos + sub.from.len ..],
                        }) catch break;
                        if (allocated) alloc.free(new_name);
                        new_name = replacement;
                        allocated = true;
                    }
                }
                if (allocated) {
                    replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
                }
            }
        }
        for (replacements.items) |r| {
            if (try names.fetchPut(r.key, r.val)) |old| alloc.free(old.value);
        }
    }

    var decorations = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(alloc);
    defer {
        var it = decorations.iterator();
        while (it.next()) |e| e.value_ptr.deinit(alloc);
        decorations.deinit();
    }
    try collectDecorations(alloc, &module, &decorations);

    // Arena for temporary allocations
    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const arena = aa.allocator();

    var out = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    defer out.deinit(alloc);
    const w = out.writer(alloc);

    try w.writeAll("// Generated by glslpp SPIR-V → WGSL cross-compiler\n\n");

    const is_fragment = module.execution_model == .Fragment;
    const is_vertex = module.execution_model == .Vertex;
    const is_compute = module.execution_model == .GLCompute;
    var use_vertex_struct = false;

    // Find entry point and function
    var entry_func_idx: ?usize = null;
    var output_var_id: ?u32 = null;
    var depth_output_var_id: ?u32 = null;
    var output_vars = std.ArrayList(u32).initCapacity(arena, 4) catch return error.OutOfMemory;
    var input_vars = std.ArrayList(struct { id: u32, type_id: u32, builtin: ?spirv.BuiltIn }).initCapacity(arena, 8) catch return error.OutOfMemory;

    // Collect input/output variables
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output) {
                const location = getDecVal(&decorations, inst.words[2], .location);
                const builtin = getDecVal(&decorations, inst.words[2], .built_in);
                if (location != null or is_fragment or is_vertex) {
                    try output_vars.append(arena, inst.words[2]);
                    if (is_fragment) {
                        // Detect depth output
                        if (builtin != null) {
                            const bi: spirv.BuiltIn = @enumFromInt(builtin.?);
                            if (bi == .frag_depth) {
                                depth_output_var_id = inst.words[2];
                            } else if (output_var_id == null) {
                                output_var_id = inst.words[2];
                            }
                        } else if (output_var_id == null) {
                            output_var_id = inst.words[2];
                        }
                    } else if (is_vertex) {
                        // For vertex shaders, prefer BuiltIn.position (gl_Position) as the return value
                        if (builtin != null) {
                            const bi: spirv.BuiltIn = @enumFromInt(builtin.?);
                            if (bi == .position) {
                                output_var_id = inst.words[2]; // position always takes priority
                            } else if (output_var_id == null) {
                                output_var_id = inst.words[2];
                            }
                        } else if (output_var_id == null) {
                            output_var_id = inst.words[2];
                        }
                    } else {
                        if (output_var_id == null) output_var_id = inst.words[2];
                    }
                }
            }
            if (sc == .Input) {
                const location = getDecVal(&decorations, inst.words[2], .location);
                const builtin_val = getDecVal(&decorations, inst.words[2], .built_in);
                const builtin: ?spirv.BuiltIn = if (builtin_val) |bv| @enumFromInt(bv) else null;
                if (location != null or builtin != null) {
                    try input_vars.append(arena, .{ .id = inst.words[2], .type_id = inst.words[1], .builtin = builtin });
                }
            }
        }
    }

    // Find entry function
    if (module.entry_point_id) |ep_id| {
        for (module.instructions, 0..) |inst, i| {
            if (inst.op == .Function and inst.words.len > 2 and inst.words[2] == ep_id) {
                entry_func_idx = i;
                break;
            }
        }
    }

    if (entry_func_idx == null) {
        // Try to find any fragment/vertex/compute function
        for (module.instructions, 0..) |inst, i| {
            if (inst.op == .Function and inst.words.len > 2) {
                entry_func_idx = i;
                break;
            }
        }
    }

    if (entry_func_idx == null) return error.NoEntryPoint;

    // Collect cbuffers and textures
    var cbuffers = std.ArrayList(struct { name: []const u8, type_id: u32, binding: u32, is_ssbo: bool, result_id: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    var textures = std.ArrayList(struct { name: []const u8, binding: u32, image_type_id: u32, is_storage: bool }).initCapacity(arena, 4) catch return error.OutOfMemory;

    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const result_type = inst.words[1];
        const result_id = inst.words[2];
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);

        const ptr_inst = getDef(&module, result_type) orelse continue;
        if (ptr_inst.op != .TypePointer or ptr_inst.words.len < 4) continue;
        const pointee_type = ptr_inst.words[3];

        switch (sc) {
            .Uniform => {
                const binding = getDecVal(&decorations, result_id, .binding) orelse 0;
                const set = getDecVal(&decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "Globals";
                const is_ssbo = hasDec(&decorations, pointee_type, .buffer_block);
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .binding = binding * 2 + set, .is_ssbo = is_ssbo, .result_id = result_id });
            },
            .StorageBuffer => {
                const binding = getDecVal(&decorations, result_id, .binding) orelse 0;
                const set = getDecVal(&decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "buffer";
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .binding = binding * 2 + set, .is_ssbo = true, .result_id = result_id });
            },
            .UniformConstant => {
                const pointee_inst = getDef(&module, pointee_type) orelse continue;
                const binding = getDecVal(&decorations, result_id, .binding) orelse 0;
                const set = getDecVal(&decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "tex";
                var is_storage = false;
                switch (pointee_inst.op) {
                    .TypeSampledImage => {
                        const img_type_id = if (pointee_inst.words.len > 2) pointee_inst.words[2] else pointee_type;
                        try textures.append(arena, .{ .name = name, .binding = binding * 2 + set, .image_type_id = img_type_id, .is_storage = false });
                    },
                    .TypeImage => {
                        if (pointee_inst.words.len > 7 and pointee_inst.words[7] == 2) is_storage = true;
                        try textures.append(arena, .{ .name = name, .binding = binding * 2 + set, .image_type_id = pointee_type, .is_storage = is_storage });
                    },
                    else => continue,
                }
            },
            else => {},
        }
    }

    // Emit Private storage class variables as module-scope declarations
    // Note: SPIR-V Private vars may be uninitialized (compiler doesn't emit init values for const globals)
    // WGSL var<private> is zero-initialized — semantically wrong but valid
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .Private) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const rt = wgslType(&module, inst.words[1], &names, arena) catch continue;
        // Check if this Private var is actually used (has loads from it)
        var has_load = false;
        for (module.instructions) |check| {
            if (check.op == .Load and check.words.len > 3 and check.words[3] == result_id) {
                has_load = true;
                break;
            }
        }
        if (!has_load) continue;
        // Check for initializer (optional 5th word in OpVariable)
        if (inst.words.len > 4) {
            const init_id = inst.words[4];
            const init_val = resolveConstantExpr(&module, &names, init_id, arena);
            if (init_val) |val| {
                try w.print("const {s}: {s} = {s};\n", .{ name, rt, val });
                continue;
            }
        }
        try w.print("var<private> {s}: {s};\n", .{ name, rt });
    }

    // Detect SSBO struct fields that are the target of OpAtomic* ops.
    // WGSL requires such fields to be declared as `atomic<T>` (or `array<atomic<T>>`
    // when the atomic op indexes into an array field). naga rejects atomic ops on
    // non-atomic typed members with: "atomic operation is done on a pointer to a non-atomic".
    var atomic_fields = AtomicFieldMap.init(arena);
    defer atomic_fields.deinit();
    collectAtomicFields(&module, &atomic_fields) catch {};

    // Emit struct forward declarations for types used in cbuffers
    var emitted_structs = std.AutoHashMap(u32, void).init(arena);
    defer emitted_structs.deinit();
    var emitted_names = std.StringHashMap(void).init(arena);
    defer emitted_names.deinit();

    for (cbuffers.items) |cb| {
        try emitStructForwardDecls(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
        try emitOneStructForwardDecl(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
    }

    // Emit struct forward declarations for types used as local variables
    var local_structs = std.AutoHashMap(u32, void).init(arena);
    defer local_structs.deinit();
    // Scan for Function-scoped variables
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                const ptr_type = getDef(&module, inst.words[1]);
                if (ptr_type) |pt| {
                    if (pt.op == .TypePointer and pt.words.len > 3) {
                        var tid = pt.words[3];
                        // Unwrap TypeArray to find struct
                        while (true) {
                            const ti = getDef(&module, tid);
                            if (ti) |tinst| {
                                if (tinst.op == .TypeArray) {
                                    tid = tinst.words[2];
                                    continue;
                                }
                            }
                            break;
                        }
                        const ti = getDef(&module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct and local_structs.get(tid) == null) {
                                local_structs.put(tid, {}) catch {};
                                try emitOneStructForwardDecl(&module, &names, tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
                            }
                        }
                    }
                }
            }
        }
    }

    // Deduplicate bindings: auto-assign sequential bindings when multiple uniforms collide
    {
        var seen_bindings = std.AutoHashMap(u32, void).init(arena);
        var next_binding: u32 = 0;
        for (cbuffers.items, 0..) |*cb, ci| {
            if (ci > 0) {
                // Check if this binding was already used
                if (seen_bindings.contains(cb.binding)) {
                    // Find next available binding
                    while (seen_bindings.contains(next_binding)) : (next_binding += 1) {}
                    cb.binding = next_binding;
                    next_binding += 1;
                }
            }
            try seen_bindings.put(cb.binding, {});
        }
    }

    // Track uniform arrays wrapped in vec4 structs (for alignment)
    var wrapped_uniform_arrays = std.AutoHashMap(u32, void).init(arena);

    // Emit uniform buffers
    for (cbuffers.items) |cb| {
        const shifted_cb_binding = common.applyBindingShift(cb.binding, options.binding_shift);
        const group = @divFloor(shifted_cb_binding, 2);
        const binding = shifted_cb_binding;
        const type_name = blk: {
            // Resolve pointer type to pointee type
            const ptr_inst = getDef(&module, cb.type_id);
            const actual_type = if (ptr_inst) |pi|
                if (pi.op == .TypePointer and pi.words.len > 3) pi.words[3] else cb.type_id
            else cb.type_id;
            break :blk try wgslType(&module, actual_type, &names, arena);
        };
        // Avoid name collision: if variable name same as type name, rename the variable
        var var_name: []const u8 = cb.name;
        if (std.mem.eql(u8, cb.name, type_name)) {
            // Find the variable's result ID and rename it in the names map
            for (module.instructions) |vinst| {
                if (vinst.op == .Variable and vinst.words.len >= 4) {
                    const vname = names.get(vinst.words[2]) orelse continue;
                    if (std.mem.eql(u8, vname, cb.name)) {
                        const new_name = try std.fmt.allocPrint(alloc, "{s}_data", .{cb.name});
                        try names.put(vinst.words[2], new_name);
                        var_name = new_name;
                        break;
                    }
                }
            }
        }
        // WGSL requires uniform arrays to have 16-byte aligned stride.
        // Wrap bare arrays in a struct to satisfy alignment.
        const ptr_inst2 = getDef(&module, cb.type_id);
        const actual_type2 = if (ptr_inst2) |pi|
            if (pi.op == .TypePointer and pi.words.len > 3) pi.words[3] else cb.type_id
        else cb.type_id;
        const is_bare_array = blk: {
            const ti = getDef(&module, actual_type2);
            break :blk ti != null and ti.?.op == .TypeArray;
        };
        if (is_bare_array and !cb.is_ssbo) {
            // WGSL uniform arrays require 16-byte aligned stride.
            // Wrap bare float/int arrays: array<f32, N> → struct { values: array<vec4f, N> }
            // Access pattern changes: u_vals[i] → u_vals.values[i].x
            const arr_type_inst = getDef(&module, actual_type2).?;
            const elem_type_id = if (arr_type_inst.words.len > 2) arr_type_inst.words[2] else 0;
            const arr_count_id = if (arr_type_inst.words.len > 3) arr_type_inst.words[3] else 0;
            const elem_inst = getDef(&module, elem_type_id);
            const is_float = elem_inst != null and elem_inst.?.op == .TypeFloat;
            const is_int = elem_inst != null and elem_inst.?.op == .TypeInt;
            if ((is_float or is_int) and arr_count_id != 0) {
                const vec_type = if (is_float) "vec4f" else "vec4i";
                // Get the constant count
                const count_inst = getDef(&module, arr_count_id);
                const count = if (count_inst) |ci| blk: {
                    if (ci.op == .Constant and ci.words.len > 3) break :blk ci.words[3];
                    break :blk 0;
                } else 0;
                if (count > 0) {
                    try w.print("struct {s}_wrapper {{ _wrapped_: array<{s}, {d}> }};\n\n", .{ var_name, vec_type, count });
                    try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: {s}_wrapper;\n\n", .{ group, binding, var_name, var_name });
                    // Update names: access chains that use this variable as base need .values prefix + .x suffix
                    for (module.instructions) |vinst| {
                        if (vinst.op == .Variable and vinst.words.len >= 4) {
                            const vname = names.get(vinst.words[2]) orelse continue;
                            if (std.mem.eql(u8, vname, var_name)) {
                                const wrapper_name = try std.fmt.allocPrint(alloc, "{s}._wrapped_", .{var_name});
                                if (try names.fetchPut(vinst.words[2], wrapper_name)) |old| alloc.free(old.value);
                                break;
                            }
                        }
                    }
                    // Track that loads from this array need .x suffix
                    // AccessChain results from this base need .x appended
                    _ = try wrapped_uniform_arrays.put(cb.result_id, {});
                    continue;
                }
            }
            // Fallback: emit as-is (may fail naga validation)
            try w.print("struct {s}_wrapper {{ values: {s} }};\n\n", .{ var_name, type_name });
            try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: {s}_wrapper;\n\n", .{ group, binding, var_name, var_name });
        } else if (cb.is_ssbo) {
            try w.print("@group({d}) @binding({d})\nvar<storage, read_write> {s}: {s};\n\n", .{ group, binding, var_name, type_name });
        } else {
            try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: {s};\n\n", .{ group, binding, var_name, type_name });
        }
    }

    // Emit workgroup variables (shared memory for compute shaders)
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Workgroup) {
                const ptr_type = getDef(&module, inst.words[1]);
                if (ptr_type) |pt| {
                    if (pt.op == .TypePointer and pt.words.len > 3) {
                        const pointee_type = pt.words[3];
                        const type_name = try wgslType(&module, pointee_type, &names, arena);
                        const var_name = names.get(inst.words[2]) orelse "shared";
                        // Emit struct declaration for array element types
                        try emitOneStructForwardDecl(&module, &names, pointee_type, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
                        try w.print("var<workgroup> {s}: {s};\n\n", .{ var_name, type_name });
                    }
                }
            }
        }
    }

    // Emit textures and samplers
    // Group sampler + texture pairs
    // Deduplicate bindings against cbuffers
    var sampler_names = std.ArrayList(struct { name: []const u8, binding: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Collect used bindings from cbuffers
    var used_tex_bindings = std.AutoHashMap(u32, void).init(arena);
    for (cbuffers.items) |cb| {
        used_tex_bindings.put(cb.binding, {}) catch {};
    }
    var next_tex_binding: u32 = 0;

    for (textures.items) |tex| {
        var tex_binding = tex.binding;
        // Avoid collision with cbuffers
        if (used_tex_bindings.contains(tex_binding)) {
            while (used_tex_bindings.contains(next_tex_binding)) : (next_tex_binding += 1) {}
            tex_binding = next_tex_binding;
            next_tex_binding += 1;
        }
        used_tex_bindings.put(tex_binding, {}) catch {};
        used_tex_bindings.put(tex_binding + 1, {}) catch {}; // sampler slot
        // Apply user-requested binding shift after collision resolution. The
        // group is derived from the shifted binding so a non-zero shift can
        // move @group as well, which is the desired behaviour for descriptor
        // remapping.
        const shifted_tex = common.applyBindingShift(tex_binding, options.binding_shift);
        const shifted_sampler = common.applyBindingShift(tex_binding + 1, options.binding_shift);
        const group = @divFloor(shifted_tex, 2);
        const binding = shifted_tex;
        // Arrayed depth textures (sampler2DArrayShadow / samplerCubeArrayShadow)
        // are emitted as texture_depth_2d_array / texture_depth_cube_array (see
        // wgslType) and the compare-sample handlers pass the array layer as a
        // separate WGSL array_index argument (see depthCompareShape). The gather
        // form (textureGatherCompare) is not yet wired for the array_index arg,
        // so it stays an honest error in its own handler rather than emitting
        // wrong-arity WGSL.
        const tex_type = try wgslType(&module, tex.image_type_id, &names, arena);
        if (tex.is_storage) {
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n\n", .{ group, binding, tex.name, tex_type });
        } else {
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n", .{ group, binding, tex.name, tex_type });
            // Emit paired sampler. A depth/comparison image (sampler2DShadow)
            // requires a sampler_comparison so textureSampleCompare /
            // textureGatherCompare typecheck; a plain `sampler` is silent-wrong.
            const sampler_name = try std.fmt.allocPrint(arena, "{s}_sampler", .{tex.name});
            const sampler_kind: []const u8 = if (imageTypeIsDepth(&module, tex.image_type_id)) "sampler_comparison" else "sampler";
            try sampler_names.append(arena, .{ .name = sampler_name, .binding = tex.binding + 1 });
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n\n", .{ group, shifted_sampler, sampler_name, sampler_kind });
        }
    }

    // Emit specialization constants as `@id(N) override NAME: TYPE = DEFAULT;`.
    // WGSL spec-const syntax (override declaration) requires the @id attribute
    // to precede the `override` keyword and applies only to scalar types
    // (bool / i32 / u32 / f32). Composite spec consts would require M3.4.
    var sc_emitted_any = false;
    for (module.instructions) |sc_inst| {
        const is_scalar_sc = sc_inst.op == .SpecConstant and sc_inst.words.len > 3;
        const is_bool_sc = (sc_inst.op == .SpecConstantTrue or sc_inst.op == .SpecConstantFalse) and sc_inst.words.len > 2;
        if (!is_scalar_sc and !is_bool_sc) continue;
        const result_id = sc_inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = sc_inst.words[1];
        const type_str = try wgslType(&module, type_id, &names, arena);
        const sid = getDecVal(&decorations, result_id, .spec_id) orelse continue;
        if (is_bool_sc) {
            const bool_val: []const u8 = if (sc_inst.op == .SpecConstantTrue) "true" else "false";
            try w.print("@id({d}) override {s}: bool = {s};\n", .{ sid, name, bool_val });
        } else {
            const default_val = sc_inst.words[3];
            // Format default per type: f32 needs decimal, i32/u32 don't.
            if (std.mem.eql(u8, type_str, "f32")) {
                const fv: f32 = @bitCast(default_val);
                try w.print("@id({d}) override {s}: {s} = {d};\n", .{ sid, name, type_str, fv });
            } else if (std.mem.eql(u8, type_str, "i32")) {
                const iv: i32 = @bitCast(default_val);
                try w.print("@id({d}) override {s}: {s} = {d};\n", .{ sid, name, type_str, iv });
            } else {
                // u32 / fallback
                try w.print("@id({d}) override {s}: {s} = {d}u;\n", .{ sid, name, type_str, default_val });
            }
        }
        sc_emitted_any = true;
    }
    // OpSpecConstantComposite: WGSL `override` only supports scalar types
    // (i32 / u32 / f32 / bool). Composite spec constants cannot be expressed
    // as `override`. We emit each scalar component as an `@id(N) override` and
    // assemble the composite via a regular `const` that references those
    // overrides — at pipeline time the WGSL implementation substitutes the
    // overrides and the const reduces to the user-overridden value.
    var sc_composite_emitted_any = false;
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantComposite or inst.words.len <= 3) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try wgslType(&module, type_id, &names, arena);
        const constituents = inst.words[3..];
        try w.writeAll("// WGSL note: composite spec consts use per-scalar @id overrides; composite reassembled below.\n");
        try w.print("const {s}: {s} = {s}(", .{ name, type_str, type_str });
        for (constituents, 0..) |c_id, i| {
            if (i > 0) try w.writeAll(", ");
            const c_name = names.get(c_id) orelse "0";
            try w.writeAll(c_name);
        }
        try w.writeAll(");\n");
        sc_composite_emitted_any = true;
    }
    // M3.5: emit OpSpecConstantOp as a derived `const` expression. WGSL
    // permits `override`s to participate in const-expression evaluation
    // at pipeline-creation time, so `const NAME: T = LEAF * 2;` correctly
    // re-evaluates when the user supplies an override for `LEAF`.
    var sc_op_emitted_any = false;
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantOp or inst.words.len != 6) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try wgslType(&module, type_id, &names, arena);
        const op_str: ?[]const u8 = switch (opcode_lit) {
            128, 129 => @as([]const u8, "+"),
            130, 131 => @as([]const u8, "-"),
            132, 133 => @as([]const u8, "*"),
            134, 135, 136 => @as([]const u8, "/"),
            else => null,
        };
        const op = op_str orelse continue;
        const op0 = names.get(inst.words[4]) orelse continue;
        const op1 = names.get(inst.words[5]) orelse continue;
        try w.print("const {s}: {s} = {s} {s} {s};\n", .{ name, type_str, op0, op, op1 });
        sc_op_emitted_any = true;
    }
    if (sc_emitted_any or sc_composite_emitted_any or sc_op_emitted_any) try w.writeAll("\n");

    // Emit non-entry functions first
    var func_ids = std.ArrayList(u32).initCapacity(arena, 8) catch return error.OutOfMemory;
    var func_idx_map = std.AutoHashMap(u32, usize).init(arena);
    for (module.instructions, 0..) |inst, i| {
        if (inst.op == .Function and inst.words.len > 2) {
            func_ids.appendAssumeCapacity(inst.words[2]);
            func_idx_map.put(inst.words[2], i) catch {};
        }
    }
    // Pre-scan: forward-declare structs used as local variable types in any function
    for (func_ids.items) |fid| {
        const fidx = func_idx_map.get(fid) orelse continue;
        const fi = module.instructions[fidx];
        // Get function type for return type
        if (fi.words.len >= 5) {
            const func_type_id = fi.words[4];
            const ft = getDef(&module, func_type_id);
            if (ft) |fti| {
                if (fti.op == .TypeFunction and fti.words.len > 2) {
                    try emitOneStructForwardDecl(&module, &names, fti.words[2], w, arena, &emitted_structs, &emitted_names, &atomic_fields);
                    // Also emit for param types
                    for (fti.words[3..]) |param_tid| {
                        try emitOneStructForwardDecl(&module, &names, param_tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
                    }
                }
            }
        }
        // Scan function body for OpVariable/OpUndef with struct types
        var si: usize = fidx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const scan = module.instructions[si];
            if (scan.op == .FunctionEnd) break;
            if (scan.op == .Variable or scan.op == .Undef or
                scan.op == .CompositeConstruct or scan.op == .Load or
                scan.op == .CompositeExtract)
            {
                if (scan.words.len > 1) {
                    const type_id = scan.words[1];
                    try emitOneStructForwardDecl(&module, &names, type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields);
                }
            }
        }
    }

    for (func_ids.items) |fid| {
        if (fid == module.entry_point_id) continue; // emit entry last
        const fidx = func_idx_map.get(fid) orelse continue;
        const fi = module.instructions[fidx];
        if (fi.words.len < 5) continue;
        // Get function type to resolve return type and params
        const func_type_id = fi.words[4]; // OpFunction: result_type, result_id, func_control, func_type
        const ft_inst = getDef(&module, func_type_id);
        if (ft_inst == null or ft_inst.?.op != .TypeFunction or ft_inst.?.words.len < 3) continue;
        // Return type (words[2] of TypeFunction)
        const ret_type = try wgslType(&module, ft_inst.?.words[2], &names, arena);
        const func_name = names.get(fid) orelse "func";

        // Detect pointer params (inout/out parameters)
        // In SPIR-V, inout params are Function-scope pointer types
        const InoutParam = struct { param_idx: usize, param_id: u32, pointee_type_id: u32, local_name: []const u8 };
        var inout_params = std.ArrayList(InoutParam).initCapacity(arena, 4) catch return error.OutOfMemory;
        var has_pointer_params = false;

        for (ft_inst.?.words[3..], 0..) |param_type_id, pi| {
            const pt_inst = getDef(&module, param_type_id);
            if (pt_inst) |pti| {
                if (pti.op == .TypePointer and pti.words.len > 3) {
                    // This is a pointer parameter — inout/out in GLSL
                    const storage_class: spirv.StorageClass = @enumFromInt(pti.words[2]);
                    if (storage_class == .Function) {
                        has_pointer_params = true;
                        const pointee_type_id = pti.words[3];
                        // Find the FunctionParameter instruction for this param
                        var param_id: u32 = 0;
                        var pidx: usize = 0;
                        for (module.instructions[fidx + 1..]) |pinst| {
                            if (pinst.op == .FunctionParameter and pinst.words.len > 2) {
                                if (pidx == pi) {
                                    param_id = pinst.words[2];
                                    break;
                                }
                                pidx += 1;
                            }
                            if (pinst.op == .Label) break;
                        }
                        const orig_name = names.get(param_id) orelse "";
                        const local_name = try std.fmt.allocPrint(arena, "_inout_{s}", .{if (orig_name.len > 0) orig_name else try std.fmt.allocPrint(arena, "p{d}", .{pi})});
                        try inout_params.append(arena, .{ .param_idx = pi, .param_id = param_id, .pointee_type_id = pointee_type_id, .local_name = local_name });
                    }
                }
            }
        }

        // Parameters (words[3..] of TypeFunction)
        var param_count: usize = 0;
        try w.print("fn {s}(", .{func_name});
        for (ft_inst.?.words[3..], 0..) |param_type_id, pi| {
            if (pi > 0) try w.writeAll(", ");
            // Check if this param is a pointer (inout/out)
            var actual_type_id = param_type_id;
            var is_inout = false;
            for (inout_params.items) |ip| {
                if (ip.param_idx == pi) {
                    actual_type_id = ip.pointee_type_id;
                    is_inout = true;
                    break;
                }
            }
            const pt = try wgslType(&module, actual_type_id, &names, arena);
            // Look up param names from the function body
            var found_name: ?[]const u8 = null;
            var pidx: usize = 0;
            for (module.instructions[fidx + 1..]) |pinst| {
                if (pinst.op == .FunctionParameter and pinst.words.len > 2) {
                    if (pidx == pi) {
                        found_name = names.get(pinst.words[2]);
                        break;
                    }
                    pidx += 1;
                }
                if (pinst.op == .Label) break;
            }
            const p_name = found_name orelse try std.fmt.allocPrint(arena, "p{d}", .{pi});
            try w.print("{s}: {s}", .{ p_name, pt });
            param_count += 1;
        }

        // Determine return type
        if (has_pointer_params and inout_params.items.len > 0) {
            // Need to return modified inout param values
            if (std.mem.eql(u8, ret_type, "void")) {
                if (inout_params.items.len == 1) {
                    // Single out param: return the pointee type directly
                    const out_type = try wgslType(&module, inout_params.items[0].pointee_type_id, &names, arena);
                    try w.print(") -> {s} {{\n", .{out_type});
                } else {
                    // Multiple out params: return a struct
                    // TODO: implement struct return for multiple out params
                    try w.writeAll(") {\n");
                }
            } else {
                // Non-void return + out params: return a struct
                // TODO: implement struct return for non-void + out params
                try w.print(") -> {s} {{\n", .{ret_type});
            }
        } else if (std.mem.eql(u8, ret_type, "void")) {
            try w.writeAll(") {\n");
        } else {
            try w.print(") -> {s} {{\n", .{ret_type});
        }

        // Emit local var declarations for inout params
        for (inout_params.items) |ip| {
            const pt = try wgslType(&module, ip.pointee_type_id, &names, arena);
            const orig_name = names.get(ip.param_id) orelse "";
            try writeIndentStatic(w, 1);
            try w.print("var {s}: {s} = {s};\n", .{ ip.local_name, pt, if (orig_name.len > 0) orig_name else "0" });
        }

        // Remap pointer param IDs to local var names in the names map
        // Save old names to restore later (in case of shared IDs)
        var saved_names = std.ArrayList(struct { id: u32, name: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
        for (inout_params.items) |ip| {
            const old_name = names.get(ip.param_id);
            if (old_name) |n| {
                try saved_names.append(arena, .{ .id = ip.param_id, .name = n });
            }
            const local_copy = try alloc.dupe(u8, ip.local_name);
            if (try names.fetchPut(ip.param_id, local_copy)) |old| alloc.free(old.value);
        }
        defer {
            // Restore original names
            for (saved_names.items) |sn| {
                const restored = alloc.dupe(u8, sn.name) catch continue;
                if (names.fetchPut(sn.id, restored) catch null) |old| alloc.free(old.value);
            }
        }

        const inout_ret_name: ?[]const u8 = if (has_pointer_params and inout_params.items.len == 1 and std.mem.eql(u8, ret_type, "void")) inout_params.items[0].local_name else null;
        try emitBody(&module, &names, &decorations, fidx, w, alloc, arena, inout_ret_name, null, null, &wrapped_uniform_arrays);

        try w.writeAll("}\n\n");
    }

    // Emit VertexOutput struct if vertex shader has multiple outputs
    var vertex_output_fields = std.ArrayList(struct { name: []const u8, type_name: []const u8, builtin: ?[]const u8, location: ?u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Detect depth output for fragment shaders
    var use_frag_depth_struct = false;
    var use_frag_mrt_struct = false;
    if (is_fragment and depth_output_var_id != null) {
        try w.writeAll("struct FragmentOutput {\n");
        try w.writeAll("    @location(0) color: vec4f,\n");
        try w.writeAll("    @builtin(frag_depth) depth: f32,\n");
        try w.writeAll("}\n\n");
        use_frag_depth_struct = true;
    } else if (is_fragment and output_vars.items.len > 1) {
        // Multiple render targets — emit FragmentOutput struct
        try w.writeAll("struct FragmentOutput {\n");
        for (output_vars.items, 0..) |ovid, i| {
            const loc = getDecVal(&decorations, ovid, .location) orelse i;
            const var_name = names.get(ovid) orelse continue;
            try w.print("    @location({d}) {s}: vec4f,\n", .{loc, var_name});
        }
        try w.writeAll("}\n\n");
        use_frag_mrt_struct = true;
    }
    if (is_vertex and output_vars.items.len > 1) {
        for (output_vars.items) |ovid| {
            const builtin_val = getDecVal(&decorations, ovid, .built_in);
            const loc_val = getDecVal(&decorations, ovid, .location);
            const var_name = names.get(ovid) orelse continue;
            const var_def = getDef(&module, ovid) orelse continue;
            const ptr_def = getDef(&module, var_def.words[1]);
            var actual_type: u32 = var_def.words[1];
            if (ptr_def) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
            }
            const type_name = try wgslType(&module, actual_type, &names, arena);
            var bi_name: ?[]const u8 = null;
            if (builtin_val) |bv| {
                const bi: spirv.BuiltIn = @enumFromInt(bv);
                bi_name = switch (bi) {
                    .position => "position",
                    .point_size => "__point_size", // not standard WGSL
                    else => null,
                };
            }
            try vertex_output_fields.append(arena, .{ .name = var_name, .type_name = type_name, .builtin = bi_name, .location = loc_val });
        }
    }

    if (vertex_output_fields.items.len > 1) {
        use_vertex_struct = true;
        // Sort: builtin fields first (required by WGSL: @builtin(position) must be first)
        {
            var fi: usize = 1;
            while (fi < vertex_output_fields.items.len) : (fi += 1) {
                const key = vertex_output_fields.items[fi];
                var j: usize = fi;
                while (j > 0 and vertex_output_fields.items[j - 1].builtin == null and key.builtin != null) : (j -= 1) {
                    vertex_output_fields.items[j] = vertex_output_fields.items[j - 1];
                }
                vertex_output_fields.items[j] = key;
            }
        }
        try w.writeAll("struct VertexOutput {\n");
        var auto_loc: u32 = 0;
        for (vertex_output_fields.items) |field| {
            if (field.builtin) |bi| {
                try w.print("    @builtin({s}) {s}: {s},\n", .{ bi, field.name, field.type_name });
            } else if (field.location) |loc| {
                auto_loc = loc + 1;
                try w.print("    @location({d}) {s}: {s},\n", .{ loc, field.name, field.type_name });
            } else {
                try w.print("    @location({d}) {s}: {s},\n", .{ auto_loc, field.name, field.type_name });
                auto_loc += 1;
            }
        }
        try w.writeAll("}\n\n");
    }

    // Emit entry function
    const entry_stage: []const u8 = if (is_fragment) "@fragment" else if (is_vertex) "@vertex" else if (is_compute) "@compute" else "@fragment";

    if (is_compute) {
        const ls = module.local_size;
        try w.print("@compute @workgroup_size({d}, {d}, {d})\nfn main(", .{ls[0], ls[1], ls[2]});
    } else {
        try w.print("{s}\nfn main(", .{entry_stage});
    }

    // Input parameters
    for (input_vars.items, 0..) |iv, i| {
        if (i > 0) try w.writeAll(", ");
        const ptr_inst = getDef(&module, iv.type_id);
        var actual_type = iv.type_id;
        if (ptr_inst) |pi| {
            if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
        }
        const type_name = try wgslType(&module, actual_type, &names, arena);
        const var_name = names.get(iv.id) orelse "input";
        if (iv.builtin) |bi| {
            const builtin_name: []const u8 = switch (bi) {
                .frag_coord => "position",
                .front_facing => "front_facing",
                .frag_depth => "frag_depth",
                .position => "position",
                .vertex_id => "vertex_index",
                .instance_id => "instance_index",
                .vertex_index => "vertex_index",
                .instance_index => "instance_index",
                .global_invocation_id => "global_invocation_id",
                .local_invocation_id => "local_invocation_id",
                .workgroup_id => "workgroup_id",
                .num_workgroups => "num_workgroups",
                .local_invocation_index => "local_invocation_index",
                .workgroup_size => "workgroup_size",
                .primitive_id => "primitive_id",
                .invocation_id => "local_invocation_index",
                .sample_id => "sample_index",
                .sample_position => "sample_position",
                .view_index => "view_index",
                .layer => "view_index",
                else => "position",
            };
            try w.print("@builtin({s}) {s}: {s}", .{ builtin_name, var_name, type_name });
        } else {
            const loc = getDecVal(&decorations, iv.id, .location) orelse i;
            try w.print("@location({d}) {s}: {s}", .{ loc, var_name, type_name });
        }
    }

    // Return type
    if (is_fragment and output_vars.items.len > 0 and output_var_id != null) {
        if (use_frag_depth_struct or use_frag_mrt_struct) {
            try w.writeAll(") -> FragmentOutput {\n");
        } else {
            const ov = output_var_id.?;
            const ptr_inst = getDef(&module, getDef(&module, ov).?.words[1]);
            var actual_type: u32 = undefined;
            if (ptr_inst) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3] else actual_type = ov;
            } else actual_type = ov;
            const type_name = try wgslType(&module, actual_type, &names, arena);
            try w.print(") -> @location(0) {s} {{\n", .{type_name});
        }
    } else if (is_vertex and output_vars.items.len > 0 and output_var_id != null) {
        if (output_vars.items.len == 1) {
            // Single output — emit simple return type
            const ov = output_var_id.?;
            const builtin = getDecVal(&decorations, ov, .built_in);
            const ptr_inst = getDef(&module, getDef(&module, ov).?.words[1]);
            var actual_type: u32 = undefined;
            if (ptr_inst) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3] else actual_type = ov;
            } else actual_type = ov;
            const type_name = try wgslType(&module, actual_type, &names, arena);
            if (builtin != null) {
                const bi: spirv.BuiltIn = @enumFromInt(builtin.?);
                const bi_name: []const u8 = switch (bi) {
                    .position => "position",
                    else => "position",
                };
                try w.print(") -> @builtin({s}) {s} {{\n", .{ bi_name, type_name });
            } else {
                const loc = getDecVal(&decorations, ov, .location) orelse 0;
                try w.print(") -> @location({d}) {s} {{\n", .{ loc, type_name });
            }
        } else {
            // Multiple outputs — emit struct return type
            try w.writeAll(") -> VertexOutput {\n");
            use_vertex_struct = true;
        }
    } else {
        try w.writeAll(") {\n");
    }

    // Pre-scan: detect simple output variable pattern (single store before return)
    // If output var is stored to exactly once, we can return the value directly
    var direct_return_value: ?[]const u8 = null;
    var depth_return_value: ?[]const u8 = null;
    var mrt_return_values = std.ArrayList(struct { var_name: []const u8, value: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    var skip_output_var_decl = false;
    if (!use_vertex_struct and output_var_id != null) {
        const ov = output_var_id.?;
        var store_count: usize = 0;
        var last_stored_value: ?[]const u8 = null;
        // Scan function body for stores to the output variable
        var sci: usize = entry_func_idx.? + 1;
        while (sci < module.instructions.len) : (sci += 1) {
            const si = module.instructions[sci];
            if (si.op == .FunctionEnd) break;
            if (si.op == .Store and si.words.len >= 3 and si.words[1] == ov) {
                store_count += 1;
                last_stored_value = names.get(si.words[2]);
            }
            // Track depth output stores
            if (depth_output_var_id != null and si.op == .Store and si.words.len >= 3 and si.words[1] == depth_output_var_id.?) {
                depth_return_value = names.get(si.words[2]);
            }
            // Track MRT output stores
            if (use_frag_mrt_struct and si.op == .Store and si.words.len >= 3) {
                for (output_vars.items) |ovid| {
                    if (si.words[1] == ovid) {
                        const vn = names.get(ovid) orelse continue;
                        const val = names.get(si.words[2]) orelse continue;
                        try mrt_return_values.append(arena, .{ .var_name = vn, .value = val });
                    }
                }
            }
        }
        if (store_count == 1 and last_stored_value != null) {
            direct_return_value = last_stored_value.?;
            skip_output_var_decl = true;
        }
        // MRT: check all output vars have exactly 1 store
        if (use_frag_mrt_struct) {
            skip_output_var_decl = true;
        }
    }

    // Declare output variable(s) as local (skip if direct return)
    if (!skip_output_var_decl) {
        if (use_vertex_struct) {
            try w.writeAll("    var vertex_out: VertexOutput;\n");
            for (output_vars.items) |ovid| {
                const var_name = names.get(ovid) orelse continue;
                const alias = try std.fmt.allocPrint(alloc, "vertex_out.{s}", .{var_name});
                if (names.fetchPut(ovid, alias) catch null) |old| alloc.free(old.value);
            }
        } else if ((is_fragment or is_vertex) and output_var_id != null) {
            const ov = output_var_id.?;
            const var_inst = getDef(&module, ov).?;
            const ptr_inst = getDef(&module, var_inst.words[1]);
            var actual_type: u32 = undefined;
            if (ptr_inst) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3] else actual_type = var_inst.words[1];
            } else actual_type = var_inst.words[1];
            const type_name = try wgslType(&module, actual_type, &names, arena);
            const var_name = names.get(ov) orelse "out";
            try w.print("    var {s}: {s};\n", .{ var_name, type_name });
        }
    }

    // Build MRT skip set for stores
    var mrt_skip_set = std.AutoHashMap(u32, void).init(arena);
    if (use_frag_mrt_struct) {
        for (output_vars.items) |ovid| {
            try mrt_skip_set.put(ovid, {});
        }
    }

    // Emit function body
    try emitBody(&module, &names, &decorations, entry_func_idx.?, w, alloc, arena, null, if (skip_output_var_decl) output_var_id else null, if (mrt_skip_set.count() > 0) &mrt_skip_set else null, &wrapped_uniform_arrays);

    // Return output var
    if (use_frag_depth_struct) {
        const color_val = direct_return_value orelse (if (output_var_id != null) names.get(output_var_id.?) orelse "vec4f()" else "vec4f()");
        const depth_val = depth_return_value orelse "0.0";
        try w.print("    return FragmentOutput({s}, {s});\n", .{ color_val, depth_val });
    } else if (use_frag_mrt_struct) {
        // Build FragmentOutput with stored values for each output
        var mrt_parts = std.ArrayList(u8).initCapacity(arena, 256) catch return error.OutOfMemory;
        for (output_vars.items) |ovid| {
            const vn = names.get(ovid) orelse continue;
            // Find the last stored value for this output var
            var stored_val: ?[]const u8 = null;
            for (mrt_return_values.items) |rv| {
                if (std.mem.eql(u8, rv.var_name, vn)) stored_val = rv.value;
            }
            if (mrt_parts.items.len > 0) try mrt_parts.appendSlice(arena, ", ");
            try mrt_parts.appendSlice(arena, stored_val orelse "vec4f()");
        }
        try w.print("    return FragmentOutput({s});\n", .{mrt_parts.items});
    } else if (use_vertex_struct) {
        try w.writeAll("    return vertex_out;\n");
    } else if (direct_return_value != null) {
        try w.print("    return {s};\n", .{direct_return_value.?});
    } else if ((is_fragment or is_vertex) and output_var_id != null) {
        const var_name = names.get(output_var_id.?) orelse "out";
        try w.print("    return {s};\n", .{var_name});
    }

    try w.writeAll("}\n");

    // Post-process: replace 'var' with 'let' for immutable variables
    const raw = try out.toOwnedSlice(alloc);
    const result = try letVarOptimization(alloc, raw);
    alloc.free(raw);

    return result;
}

// ---------------------------------------------------------------------------
// let/var optimization — replace 'var' with 'let' for immutable variables
// ---------------------------------------------------------------------------

fn letVarOptimization(alloc: std.mem.Allocator, wgsl: []const u8) ![]const u8 {
    // Strategy: find all declarations of the form 'var <name>:' with initializers.
    // If the name doesn't appear as a reassignment target ("<name> =" without preceding 'var'),
    // replace 'var' with 'let'.

    var arena_impl = std.heap.ArenaAllocator.init(alloc);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var mutable_names = std.StringHashMap(void).init(arena);

    // Pass 1: Find names that are reassigned (lines matching '<name> =' without 'var'/'let' prefix)
    var line_start: usize = 0;
    while (line_start < wgsl.len) {
        const le = if (std.mem.indexOfScalarPos(u8, wgsl, line_start, '\n')) |e| e else wgsl.len;
        const line = wgsl[line_start..le];

        // Skip declaration lines
        if (std.mem.indexOf(u8, line, "var ") != null or std.mem.indexOf(u8, line, "let ") != null) {
            line_start = le + 1;
            continue;
        }

        // Look for reassignment pattern: '<name> = ...' (not '==') or '<name>[...] = ...'
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len > 0) {
            if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
                const potential_name = trimmed[0..space_idx];
                if (space_idx + 2 < trimmed.len and trimmed[space_idx + 1] == '=' and trimmed[space_idx + 2] != '=') {
                    const name_copy = try arena.dupe(u8, potential_name);
                    try mutable_names.put(name_copy, {});
                }
            }
            // Also check for indexed assignment: name[...] = value
            if (std.mem.indexOfScalar(u8, trimmed, '[')) |bracket_idx| {
                const potential_name = trimmed[0..bracket_idx];
                // Find the closing bracket and check for ' ='
                if (std.mem.indexOfScalarPos(u8, trimmed, bracket_idx, ']')) |close_idx| {
                    if (close_idx + 2 < trimmed.len and trimmed[close_idx + 1] == ' ' and trimmed[close_idx + 2] == '=') {
                        const name_copy = try arena.dupe(u8, potential_name);
                        try mutable_names.put(name_copy, {});
                    }
                }
            }
        }

        line_start = le + 1;
    }

    // Pass 2: Replace 'var <name>:' → 'let <name>:' for immutable variables
    var out = std.ArrayList(u8).initCapacity(alloc, wgsl.len) catch return wgsl;
    defer out.deinit(alloc);

    var pos: usize = 0;
    while (pos < wgsl.len) {
        const var_pos = std.mem.indexOfPos(u8, wgsl, pos, "var ") orelse {
            try out.appendSlice(alloc, wgsl[pos..]);
            break;
        };

        try out.appendSlice(alloc, wgsl[pos..var_pos]);
        const after_var = var_pos + 4;
        if (after_var >= wgsl.len) {
            try out.appendSlice(alloc, "var ");
            pos = after_var;
            continue;
        }

        const colon_pos = std.mem.indexOfScalarPos(u8, wgsl, after_var, ':') orelse {
            try out.appendSlice(alloc, "var ");
            pos = after_var;
            continue;
        };
        const name = wgsl[after_var..colon_pos];

        // Check for initializer on same line
        const le2 = std.mem.indexOfScalarPos(u8, wgsl, colon_pos, '\n') orelse wgsl.len;
        const rest_of_line = wgsl[colon_pos..le2];
        const has_initializer = std.mem.indexOf(u8, rest_of_line, "= ") != null or
            std.mem.endsWith(u8, rest_of_line, "=");

        if (has_initializer and !mutable_names.contains(name)) {
            try out.appendSlice(alloc, "let ");
        } else {
            try out.appendSlice(alloc, "var ");
        }

        pos = after_var;
    }

    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Body emitter
// ---------------------------------------------------------------------------

fn emitBody(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), func_idx: usize, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, inout_return: ?[]const u8, skip_store_target: ?u32, skip_store_targets: ?*const std.AutoHashMap(u32, void), wrapped_uniform_arrays: *const std.AutoHashMap(u32, void)) !void {
    _ = decorations;
    _ = wrapped_uniform_arrays;
    var indent: u32 = 1; // base function body indentation (4 spaces)

    // Helper to write current indentation
    const writeInd = struct {
        fn write(writer: anytype, depth: u32) !void {
            try writeIndentStatic(writer, depth);
        }
    }.write;

    // Skip function declaration instructions
    var i: usize = func_idx + 1;
    // Skip FunctionParameter instructions (parameters declared in function signature)
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];
        if (inst.op == .Label) { i += 1; break; }
        if (inst.op == .FunctionParameter) continue;
        break;
    }

    // Control flow state tracking
    var pending_merge: ?u32 = null;
    var pending_false_label: ?u32 = null; // false branch label (if has else)
    var if_depth: u32 = 0;
    var merge_stack = std.ArrayList(?u32).initCapacity(arena, 8) catch return;
    defer merge_stack.deinit(arena);

    // Loop state tracking
    var loop_merge_label: ?u32 = null;
    var loop_continue_label: ?u32 = null;
    var loop_header_label: ?u32 = null;
    var in_loop: bool = false;
    var in_continue_block: bool = false;
    const PhiUpdate = struct { result_id: u32, value_id: u32 };
    var phi_updates = std.ArrayList(PhiUpdate).initCapacity(arena, 8) catch return;
    defer phi_updates.deinit(arena);
    // Selection phi: [merge_label] → list of (result_id, value_id, predecessor_label)
    const SelPhi = struct { result_id: u32, value_id: u32, pred_label: u32 };
    var sel_phis = std.AutoArrayHashMap(u32, std.ArrayList(SelPhi)).init(arena);
    {
        var si: usize = func_idx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .Phi and scan_inst.words.len >= 7) {
                // Check if this phi belongs to a loop header (skip — loop phis are handled separately)
                var is_loop_phi = false;
                var pk: usize = si + 1;
                while (pk < @min(si + 30, module.instructions.len)) : (pk += 1) {
                    if (module.instructions[pk].op == .LoopMerge) { is_loop_phi = true; break; }
                    if (module.instructions[pk].op == .SelectionMerge or module.instructions[pk].op == .Label or module.instructions[pk].op == .FunctionEnd) break;
                }
                if (is_loop_phi) continue;

                // Find the merge label this phi belongs to (the label of the current block)
                var merge_label: ?u32 = null;
                var li: usize = si;
                while (li > func_idx) : (li -= 1) {
                    if (module.instructions[li].op == .Label and module.instructions[li].words.len > 1) {
                        merge_label = module.instructions[li].words[1];
                        break;
                    }
                }
                if (merge_label) |ml| {
                    // Parse all (value, predecessor) pairs
                    var pi: usize = 3;
                    while (pi + 1 < scan_inst.words.len) : (pi += 2) {
                        const val_id = scan_inst.words[pi];
                        const pred_id = scan_inst.words[pi + 1];
                        const gop = sel_phis.getOrPut(ml) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(SelPhi).initCapacity(arena, 2) catch continue;
                        gop.value_ptr.appendAssumeCapacity(.{ .result_id = scan_inst.words[2], .value_id = val_id, .pred_label = pred_id });
                    }
                }
            }
        }
    }
    var loop_stack = std.ArrayList(struct { merge: u32, cont: u32, header: u32, phi_start: usize, phi_end: usize }).initCapacity(arena, 4) catch return;
    defer loop_stack.deinit(arena);
    // Track phi range for pending loop (Phi processed before LoopMerge)
    var pending_phi_start: usize = 0;

    // Deferred instruction range for loop header instructions
    // Instructions between Phi and LoopMerge must be emitted INSIDE the loop
    var defer_start: ?usize = null;
    var defer_active = false;

    // Pre-scan: build use counts for result IDs to enable single-use load inlining
    var use_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    var def_op = std.AutoHashMapUnmanaged(u32, spirv.Op).empty;
    {
        var si: usize = func_idx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            // Record the defining opcode for result IDs
            if (scan_inst.words.len > 2) {
                // Most opcodes: words[1]=type, words[2]=result
                // Record only for opcodes that produce named results
                if (scan_inst.op != .Label and scan_inst.op != .FunctionParameter) {
                    try def_op.put(arena, scan_inst.words[2], scan_inst.op);
                }
            }
            // Count uses of each ID referenced in the instruction
            for (scan_inst.words[@min(1, scan_inst.words.len)..]) |word| {
                // Count uses of each ID referenced in the instruction
                const entry = try use_count.getOrPutValue(arena, word, 0);
                entry.value_ptr.* += 1;
            }
        }
    }

    // Pre-scan: process AccessChain instructions to set names before expression inlining
    // Without this, inline expressions reference raw names like v27 instead of v15.colors[v25]
    {
        var aci: usize = func_idx + 1;
        while (aci < module.instructions.len) : (aci += 1) {
            const ac_inst = module.instructions[aci];
            if (ac_inst.op == .FunctionEnd) break;
            if (ac_inst.op == .AccessChain and ac_inst.words.len > 3) {
                const result_id = ac_inst.words[2];
                const base_id = ac_inst.words[3];
                var expr = buildAccessExpr(module, names, base_id, ac_inst.words[4..], alloc) catch continue;
                if (expr.len > 0) {
                    // Append .x for wrapped uniform arrays (array<f32,N> → array<vec4f,N>)
                    // Check if base variable was renamed to include .values
                    const base_name = names.get(base_id) orelse "";
                    _ = base_name; // used in debug below
                    // Check by examining the expr itself — if it contains ._wrapped_[
                    if (std.mem.indexOf(u8, expr, "._wrapped_[") != null) {
                        const with_x = try std.fmt.allocPrint(alloc, "{s}.x", .{expr});
                        alloc.free(expr);
                        expr = with_x;
                    }
                    if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
                }
            }
        }
    }

    // For single-use OpLoad results, inline the source pointer name
    // This eliminates unnecessary 'let vN = ptr;' declarations
    // BUT: don't inline if the pointer is also a Store target (to preserve load-before-store semantics)
    var inline_loads = std.AutoHashMap(u32, void).init(arena);
    // Build set of pointer IDs that are Store targets in this function
    var store_targets = std.AutoHashMap(u32, void).init(arena);
    {
        var si: usize = func_idx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .Store and scan_inst.words.len > 1) {
                store_targets.put(scan_inst.words[1], {}) catch {};
            }
        }
    }
    {
        var it = def_op.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .Load or entry.value_ptr.* == .CopyObject) {
                const result_id = entry.key_ptr.*;
                const uses = use_count.get(result_id) orelse 0;
                if (uses <= 6) { // Allow up to 5 actual uses for name propagation
                    // Find the source pointer for this load
                    const load_inst = getDef(module, result_id) orelse continue;
                    if (load_inst.words.len > 3) {
                        const ptr_id = load_inst.words[3];
                        const ptr_name = names.get(ptr_id) orelse continue;
                        // Don't inline loads from pointers that are Store targets
                        // — they might be overwritten, so we need to capture the current value
                        if (store_targets.contains(ptr_id)) continue;
                        // Only inline if the pointer has a meaningful name and inlining
                        // doesn't create a self-assignment (e.g., let u_time = u_time)
                        const current_name = names.get(result_id) orelse "";
                        if (ptr_name.len > 0 and !std.mem.eql(u8, ptr_name, current_name)) {
                            // Set the load result's name to the pointer's name
                            // This effectively inlines the load
                            const name_copy = try alloc.dupe(u8, ptr_name);
                            // Store the old name so it gets freed in cleanup
                            if (try names.fetchPut(result_id, name_copy)) |old| {
                                alloc.free(old.value);
                            }
                            try inline_loads.put(result_id, {});
                        } else if (std.mem.eql(u8, ptr_name, current_name) and ptr_name.len > 0) {
                            // Name conflict: load result has same name as pointer
                            // Rename to avoid self-assignment (let u_val = u_val)
                            var buf = std.ArrayList(u8).initCapacity(alloc, ptr_name.len + 8) catch continue;
                            try buf.appendSlice(alloc, ptr_name);
                            try buf.appendSlice(alloc, "_ld");
                            const new_name = try buf.toOwnedSlice(alloc);
                            if (try names.fetchPut(result_id, new_name)) |old| {
                                alloc.free(old.value);
                            }
                        }
                    }
                }
            }
        }
    }

    // Save old names for extract results before renaming (for stale name fixup)
    var extract_old_names = std.AutoHashMap(u32, []const u8).init(arena);
    {
        var sni: usize = func_idx + 1;
        while (sni < module.instructions.len) : (sni += 1) {
            const sn = module.instructions[sni];
            if (sn.op == .FunctionEnd) break;
            if (sn.op == .CompositeExtract and sn.words.len > 2) {
                if (names.get(sn.words[2])) |old| {
                    // Use arena: extract_old_names is arena-allocated and only
                    // read within this function, so the value strings should
                    // live in arena too (otherwise they leak when arena is freed).
                    extract_old_names.put(sn.words[2], arena.dupe(u8, old) catch continue) catch {};
                }
            }
        }
    }

    // Pre-scan: inline single-use CompositeExtract results (v15 = v14.x → rename v15 to v14.x)
    // Process in instruction order so parent extracts are renamed before children
    {
        var ii: usize = func_idx + 1;
        while (ii < module.instructions.len) : (ii += 1) {
            const scan_inst = module.instructions[ii];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op != .CompositeExtract or scan_inst.words.len <= 4) continue;
            const result_id = scan_inst.words[2];
            const uses = use_count.get(result_id) orelse 0;
            if (uses > 3 or uses < 2) continue;
            {
                const source_id = scan_inst.words[3];
                const source_def = getDef(module, source_id);
                if (source_def) |sd| {
                    if (sd.op == .Load or sd.op == .CopyObject) {
                        if (sd.words.len > 3) {
                            const ptr_def = getDef(module, sd.words[3]);
                            if (ptr_def) |pd| {
                                if (pd.op == .AccessChain) continue; // skip
                            }
                        }
                    }
                }
                const composite_name = resolveSourceName(module, names, source_id, 0) orelse continue;
                const idx = scan_inst.words[4];
                const source_type = resolveTypeOf(module, scan_inst.words[3]);
                var is_struct_field = false;
                var is_matrix_col = false;
                var field_name_buf: [32]u8 = undefined;
                const field_name: []const u8 = if (source_type) |st| blk: {
                    const st_def = getDef(module, st);
                    if (st_def) |sd2| {
                        if (sd2.op == .TypeStruct) {
                            is_struct_field = true;
                            break :blk getMemberName(module, st, idx, &field_name_buf);
                        }
                        if (sd2.op == .TypeMatrix) {
                            is_matrix_col = true;
                            break :blk "";
                        }
                    }
                    break :blk "";
                } else "";
                var new_name_buf: []const u8 = undefined;
                const suffix: []const u8 = if (is_struct_field) field_name else if (is_matrix_col) "" else switch (idx) {
                    0 => ".x",
                    1 => ".y",
                    2 => ".z",
                    3 => ".w",
                    else => "",
                };
                if (is_struct_field) {
                    new_name_buf = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ composite_name, suffix });
                } else if (is_matrix_col) {
                    new_name_buf = try std.fmt.allocPrint(alloc, "{s}[{d}]", .{ composite_name, idx });
                } else if (idx <= 3) {
                    new_name_buf = try std.fmt.allocPrint(alloc, "{s}{s}", .{ composite_name, suffix });
                } else continue;
                const current_name = names.get(result_id) orelse "";
                if (!std.mem.eql(u8, current_name, new_name_buf)) {
                    if (try names.fetchPut(result_id, new_name_buf)) |old| {
                        alloc.free(old.value);
                    }
                    try inline_loads.put(result_id, {});
                } else {
                    // No rename needed — release the buffer we just allocated.
                    alloc.free(new_name_buf);
                }
            }
        }
    }

    // Fix stale names: replace old extract names with new ones in all name values
    // This fixes AccessChain/load names that captured the pre-rename extract name (e.g., v11 → gl_GlobalInvocationID.x)
    {
        var fixup_names = std.ArrayList(struct { id: u32, new_val: []const u8 }).initCapacity(arena, 32) catch unreachable;
        var rn_it = names.iterator();
        while (rn_it.next()) |entry| {
            const id = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            var updated = val;
            var changed_any = false;
            // Apply all extract renames
            var eon_it = extract_old_names.iterator();
            while (eon_it.next()) |eon| {
                const old_name = eon.value_ptr.*;
                if (old_name.len < 2) continue;
                const new_name = names.get(eon.key_ptr.*) orelse continue;
                if (std.mem.eql(u8, old_name, new_name)) continue; // no change
                // Replace all occurrences of old_name in val
                while (std.mem.indexOf(u8, updated, old_name)) |pos| {
                    // Check word boundaries to avoid partial matches
                    const before_ok = pos == 0 or switch (updated[pos - 1]) { ' ', '(', ',', '[', '+', '-', '*', '/', '=' => true, else => false };
                    const after_idx = pos + old_name.len;
                    const after_ok = after_idx >= updated.len or switch (updated[after_idx]) { ' ', ')', ',', ']', '+', '-', '*', '/', '=', '.', '\t' => true, else => false };
                    if (before_ok and after_ok) {
                        const replacement = try std.mem.concat(alloc, u8, &[_][]const u8{ updated[0..pos], new_name, updated[after_idx..] });
                        updated = replacement;
                        changed_any = true;
                    } else break; // avoid infinite loop on non-match
                }
            }
            if (changed_any) {
                fixup_names.append(arena, .{ .id = id, .new_val = updated }) catch {};
            }
        }
        for (fixup_names.items) |fn_item| {
            if (try names.fetchPut(fn_item.id, fn_item.new_val)) |old| alloc.free(old.value);
        }
    }

    // Pre-scan: identify dead CompositeExtract results that will be absorbed by swizzle optimization
    var dead_extracts = std.AutoHashMap(u32, void).init(arena);
    var dead_conditions = std.AutoHashMap(u32, void).init(arena);
    {
        var si: usize = func_idx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .CompositeConstruct and scan_inst.words.len > 3) {
                // Check for leading sequential extracts from the same source
                var lead_source: ?u32 = null;
                var lead_count: usize = 0;
                for (scan_inst.words[3..], 0..) |comp_id, ci| {
                    const comp_def = getDef(module, comp_id) orelse break;
                    if (comp_def.op == .CompositeExtract and comp_def.words.len > 4) {
                        if (ci == 0) {
                            lead_source = comp_def.words[3];
                            lead_count = 1;
                        } else if (comp_def.words[3] == lead_source.? and comp_def.words[4] == ci) {
                            lead_count += 1;
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                if (lead_count >= 2 and lead_source != null) {
                    // Mark the leading CompositeExtract results as dead
                    // ONLY if they're not used elsewhere (single use absorbed by swizzle)
                    for (scan_inst.words[3..], 0..) |comp_id, ci| {
                        if (ci >= lead_count) break;
                        const ext_uses = use_count.get(comp_id) orelse 0;
                        // use_count includes definition (1) + uses. For single-use, total = 2.
                        // Only mark dead if this CompositeConstruct is the sole consumer.
                        if (ext_uses <= 2) {
                            dead_extracts.put(comp_id, {}) catch {};
                        }
                    }
                }
            }
        }
    }

    // Pre-scan: identify dead conditions that will be inlined into BranchConditional
    {
        var ci: usize = func_idx + 1;
        while (ci < module.instructions.len) : (ci += 1) {
            const scan_inst = module.instructions[ci];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .BranchConditional and scan_inst.words.len >= 4) {
                const cond_id = scan_inst.words[1];
                const true_label = scan_inst.words[2];
                const false_label = scan_inst.words[3];
                // Only mark as dead for loop exit conditions
                // (where one target is the loop merge label)
                // We detect this by checking if there's a LoopMerge with matching merge label
                var is_loop_exit = false;
                // Look backward for the nearest enclosing LoopMerge
                // We look past SelectionMerge (if-blocks inside loops are still inside the loop)
                var li: usize = ci;
                while (li > func_idx) : (li -= 1) {
                    const prev = module.instructions[li];
                    if (prev.op == .LoopMerge and prev.words.len >= 3) {
                        const merge_label = prev.words[1];
                        if (true_label == merge_label or false_label == merge_label) {
                            is_loop_exit = true;
                        }
                        break;
                    }
                }
                if (is_loop_exit) {
                    const inlined = inlineConditionExpr(module, names, cond_id, arena, 0);
                    if (inlined != null) {
                        markDeadConditions(module, cond_id, &dead_conditions, 0);
                    }
                }
            }
        }
    }

    // Pre-scan: build inline expressions for single-use arithmetic operations
    // This eliminates chains like: let v13 = v12 * 6.0; let v17 = v13 + v16; → inline v13 into v17
    var inline_exprs = std.AutoHashMap(u32, []const u8).init(arena);
    var dead_arith = std.AutoHashMap(u32, void).init(arena);
    {
        // Build set of IDs used as Store operands (these feed mutable vars, don't inline)
        var store_operands = std.AutoHashMap(u32, void).init(arena);
        var si: usize = func_idx + 1;
        while (si < module.instructions.len) : (si += 1) {
            const sinst = module.instructions[si];
            if (sinst.op == .FunctionEnd) break;
            if (sinst.op == .Store and sinst.words.len > 2) {
                store_operands.put(sinst.words[2], {}) catch {};
            }
        }
        // Build inline expressions for single-use arithmetic operations
        // These expressions are used as operands when building OTHER expressions,
        // but the original let bindings are NOT removed (to avoid dead references)
        var ii: usize = func_idx + 1;
        while (ii < module.instructions.len) : (ii += 1) {
            const scan_inst = module.instructions[ii];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.words.len < 3) continue;
            const result_id = scan_inst.words[2];
            if (!isInlineableArithOp(scan_inst.op)) continue;
            const uses = use_count.get(result_id) orelse 0;
            if (uses != 2) continue;
            if (dead_extracts.contains(result_id) or dead_conditions.contains(result_id)) continue;
            if (store_operands.contains(result_id)) continue;
            const expr = buildInlineExpr(module, names, &inline_exprs, result_id, arena, 0) orelse continue;
            try inline_exprs.put(result_id, expr);
        }
        // Second pass: find dead bindings (where the single user is also dead)
        // Fixpoint: keep iterating until no new dead IDs are found
        var changed = true;
        while (changed) {
            changed = false;
            var fp_it = inline_exprs.iterator();
            while (fp_it.next()) |entry| {
                const result_id = entry.key_ptr.*;
                if (dead_arith.contains(result_id)) continue; // already dead
                const uses = use_count.get(result_id) orelse 0;
                if (uses != 2) continue;
                // Find the single user instruction
                var user_is_dead = false;
                var fi: usize = func_idx + 1;
                while (fi < module.instructions.len) : (fi += 1) {
                    const finst = module.instructions[fi];
                    if (finst.op == .FunctionEnd) break;
                    if (finst.words.len > 2 and finst.words[2] == result_id) continue;
                    var found = false;
                    for (finst.words[@min(3, finst.words.len)..]) |fw| {
                        if (fw == result_id) { found = true; break; }
                    }
                    if (found) {
                        if (finst.words.len > 2) {
                            const user_result = finst.words[2];
                            // User is dead if it's already in dead_arith
                            if (dead_arith.contains(user_result)) {
                                user_is_dead = true;
                            }
                        }
                        break;
                    }
                }
                if (user_is_dead) {
                    dead_arith.put(result_id, {}) catch {};
                    changed = true;
                }
            }
        }
        // Revive dead IDs whose names are referenced in surviving inline expressions
        // If a dead ID's name appears in an inline_exprs value, the reference would be
        // undeclared, so we must keep the binding
        {
            var revive_blk = std.ArrayList(u32).initCapacity(arena, 16) catch unreachable;
            var revive = &revive_blk;
            var re_it = dead_arith.iterator();
            while (re_it.next()) |entry| {
                const dead_id = entry.key_ptr.*;
                const dead_name = names.get(dead_id) orelse continue;
                if (dead_name.len < 2) continue; // skip short names like "v"
                // Check if any inline_exprs value references this name
                var ie_it = inline_exprs.iterator();
                while (ie_it.next()) |ie_entry| {
                    if (dead_arith.contains(ie_entry.key_ptr.*)) continue; // skip dead exprs
                    const expr = ie_entry.value_ptr.*;
                    if (std.mem.indexOf(u8, expr, dead_name) != null) {
                        // Check it's actually a variable reference (word boundary)
                        // Simple heuristic: name is preceded by space, (, or start; followed by ), +, -, *, /, ,, space, or end
                        const pos = std.mem.indexOf(u8, expr, dead_name).?;
                        const before_ok = pos == 0 or switch (expr[pos - 1]) { ' ', '(', ',', '=', '\t' => true, else => false };
                        const after_idx = pos + dead_name.len;
                        const after_ok = after_idx >= expr.len or switch (expr[after_idx]) { ' ', ')', ',', '+', '-', '*', '/', '\t', '\n' => true, else => false };
                        if (before_ok and after_ok) {
                            revive.append(arena, dead_id) catch {};
                            break;
                        }
                    }
                }
            }
            for (revive.items) |rid| {
                _ = dead_arith.remove(rid);
            }
        }
    }

    // Emit instructions
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];

        // If deferring loop header instructions, skip them for now
        // They will be emitted inside the loop body when LoopMerge is encountered
        if (defer_active and inst.op != .LoopMerge and inst.op != .Phi) {
            continue;
        }

        // Skip dead condition bindings that were inlined into BranchConditional
        if (inst.words.len > 2 and dead_conditions.contains(inst.words[2])) {
            continue;
        }

        // Skip dead arithmetic bindings (user also inlined)
        if (inst.words.len > 2 and dead_arith.contains(inst.words[2])) {
            if (def_op.get(inst.words[2])) |def_op_val| {
                if (def_op_val == inst.op) continue;
            }
        }

        switch (inst.op) {
            .FunctionEnd => {
                while (if_depth > 0) : (if_depth -= 1) {
                    indent -= 1;
                    try writeInd(w, indent); try w.writeAll("}");
                    try w.writeAll("\n");
                }
                return;
            },
            .SelectionMerge => {
                if (inst.words.len > 1) {
                    pending_merge = inst.words[1];
                    // Pre-declare selection phi variables before the if/else block
                    if (sel_phis.count() > 0) {
                        if (sel_phis.get(pending_merge.?)) |phi_list| {
                            // Find the first (init) predecessor — get it from the Phi instruction
                            const first_phi_result = phi_list.items[0].result_id;
                            const phi_inst = getDef(module, first_phi_result);
                            const init_pred = if (phi_inst != null and phi_inst.?.words.len >= 5) phi_inst.?.words[4] else null;
                            // Emit var declarations for all phi results using init values
                            var seen = std.AutoHashMap(u32, void).init(arena);
                            for (phi_list.items) |sp| {
                                if (sp.pred_label == init_pred) {
                                    if (seen.contains(sp.result_id)) continue;
                                    try seen.put(sp.result_id, {});
                                    // Ensure the phi result has a name
                                    var phi_result = names.get(sp.result_id);
                                    if (phi_result == null) {
                                        var buf: [64]u8 = undefined;
                                        const default_name = std.fmt.bufPrint(&buf, "v{d}", .{sp.result_id}) catch "phi";
                                        const name_copy = try alloc.dupe(u8, default_name);
                                        try names.put(sp.result_id, name_copy);
                                        phi_result = name_copy;
                                    }
                                    const phi_type = try wgslType(module, getDef(module, sp.result_id).?.words[1], names, arena);
                                    // Check if the init value is defined BEFORE the SelectionMerge
                                    // If defined inside the if-else block, use a type-appropriate zero instead
                                    const init_val_name = names.get(sp.value_id);
                                    var use_init = false;
                                    if (init_val_name != null) {
                                        // Check if value_id is a constant (always safe to reference)
                                        const val_def = getDef(module, sp.value_id);
                                        if (val_def != null) {
                                            const val_op = val_def.?.op;
                                            if (val_op == .Constant or val_op == .ConstantComposite or val_op == .ConstantTrue or val_op == .ConstantFalse or val_op == .Undef) {
                                                use_init = true;
                                            } else if (val_op == .Load or val_op == .Variable) {
                                                // Loads from variables declared before the if-else are safe
                                                use_init = true;
                                            } else {
                                                // Check if the value's definition index is before this SelectionMerge
                                                var found_before = false;
                                                for (module.instructions[0..i], 0..) |minst, mi| {
                                                    if (minst.words.len > 2 and minst.words[2] == sp.value_id) {
                                                        found_before = true;
                                                        _ = mi;
                                                        break;
                                                    }
                                                }
                                                if (found_before) use_init = true;
                                            }
                                        }
                                    }
                                    if (use_init and init_val_name != null) {
                                        try writeInd(w, indent); try w.print("var {s}: {s} = {s};\n", .{ phi_result.?, phi_type, init_val_name.? });
                                    } else {
                                        try writeInd(w, indent); try w.print("var {s}: {s};\n", .{ phi_result.?, phi_type });
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .Switch => {
                // Switch selector default_label [literal target ...]
                if (inst.words.len >= 3) {
                    const selector = names.get(inst.words[1]) orelse "s";
                    const default_label = inst.words[2];
                    const merge_label = pending_merge;
                    if (merge_label != null) {
                        try writeInd(w, indent); try w.print("switch {s} {{\n", .{selector});
                        const case_ind = indent + 1;
                        const body_ind = indent + 2;
                        // Emit default case (WGSL requires exactly one default)
                        if (default_label != merge_label.?) {
                            try writeInd(w, case_ind); try w.writeAll("default: {\n");
                            // Skip to default label block, emit until merge
                            var si: usize = i + 1;
                            while (si < module.instructions.len) : (si += 1) {
                                const sinst = module.instructions[si];
                                if (sinst.op == .Label and sinst.words.len > 1 and sinst.words[1] == default_label) {
                                    // Found default label, emit instructions until merge label
                                    si += 1;
                                    while (si < module.instructions.len) : (si += 1) {
                                        const dinst = module.instructions[si];
                                        if (dinst.op == .Label and dinst.words.len > 1 and dinst.words[1] == merge_label.?) break;
                                        if (dinst.op == .Branch or dinst.op == .BranchConditional) break;
                                        if (dinst.op == .Switch) break;
                                        try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, body_ind);
                                    }
                                    break;
                                }
                            }
                            try writeInd(w, case_ind); try w.writeAll("}\n");
                        } else {
                            // Default targets merge — emit empty default (WGSL requires it)
                            try writeInd(w, case_ind); try w.writeAll("default: {\n");
                            try writeInd(w, case_ind); try w.writeAll("}\n");
                        }
                        // Emit case targets
                        var wi: usize = 3;
                        while (wi + 1 < inst.words.len) : (wi += 2) {
                            const case_val = inst.words[wi];
                            const target_label = inst.words[wi + 1];
                            if (target_label == merge_label.?) continue;
                            try writeInd(w, case_ind); try w.print("case {d}: {{\n", .{case_val});
                            // Find and emit target block
                            var si: usize = i + 1;
                            while (si < module.instructions.len) : (si += 1) {
                                const sinst = module.instructions[si];
                                if (sinst.op == .Label and sinst.words.len > 1 and sinst.words[1] == target_label) {
                                    si += 1;
                                    while (si < module.instructions.len) : (si += 1) {
                                        const dinst = module.instructions[si];
                                        if (dinst.op == .Label) break;
                                        if (dinst.op == .Branch or dinst.op == .BranchConditional) break;
                                        if (dinst.op == .Switch) break;
                                        try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, body_ind);
                                    }
                                    break;
                                }
                            }
                            try writeInd(w, case_ind); try w.writeAll("}\n");
                        }
                        try writeInd(w, indent); try w.writeAll("}\n");
                        // Skip all instructions until merge label
                        var skip_i: usize = i + 1;
                        while (skip_i < module.instructions.len) : (skip_i += 1) {
                            const sinst = module.instructions[skip_i];
                            if (sinst.op == .Label and sinst.words.len > 1 and sinst.words[1] == merge_label.?) {
                                i = skip_i;
                                break;
                            }
                        }
                        pending_merge = null;
                    }
                }
            },
            .LoopMerge => {
                // LoopMerge merge_label continue_label [control]
                if (inst.words.len >= 3) {
                    const merge = inst.words[1];
                    const cont = inst.words[2];
                    // The header label is the Label instruction for this block
                    // Scan backward past non-Label instructions to find it
                    var header: u32 = 0;
                    if (i >= 1) {
                        var prev: usize = if (i > 0) i - 1 else 0;
                        while (prev > 0) : (prev -= 1) {
                            if (module.instructions[prev].op == .Label and module.instructions[prev].words.len > 1) {
                                header = module.instructions[prev].words[1];
                                break;
                            }
                        }
                    }
                    loop_merge_label = merge;
                    loop_continue_label = cont;
                    loop_header_label = header;
                    in_loop = true;
                    in_continue_block = false;
                    const phi_start = pending_phi_start;
                    const phi_end = phi_updates.items.len;
                    try loop_stack.append(arena, .{ .merge = merge, .cont = cont, .header = header, .phi_start = phi_start, .phi_end = phi_end });
                    try writeInd(w, indent); try w.writeAll("loop {\n");
                    indent += 1;
                    // Replay deferred loop header instructions inside the loop
                    if (defer_active and defer_start != null) {
                        defer_active = false;
                        var di: usize = defer_start.?;
                        while (di < i) : (di += 1) {
                            const dinst = module.instructions[di];
                            if (dinst.op == .Nop or dinst.op == .Label) continue;
                            // Skip dead conditions that were inlined
                            if (dinst.words.len > 2 and dead_conditions.contains(dinst.words[2])) continue;
                            // Emit common instruction types inline
                            switch (dinst.op) {
                                .BranchConditional, .Branch, .SelectionMerge, .LoopMerge, .Phi, .FunctionEnd => {},
                                else => {
                                    try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, indent);
                                },
                            }
                        }
                        defer_start = null;
                    }
                }
            },
            .Phi => {
                // Emit phi as variable declaration with initial value
                if (inst.words.len >= 7) {
                    const phi_result_id = inst.words[2];

                    // Check if this phi was already pre-declared by SelectionMerge
                    var already_declared = false;
                    {
                        var spi = sel_phis.iterator();
                        while (spi.next()) |entry| {
                            for (entry.value_ptr.*.items) |sp| {
                                if (sp.result_id == phi_result_id) {
                                    already_declared = true;
                                    break;
                                }
                            }
                            if (already_declared) break;
                        }
                    }

                    var phi_result = names.get(phi_result_id);
                    // If phi result has no name, assign a default one
                    if (phi_result == null) {
                        var buf: [64]u8 = undefined;
                        const default_name = std.fmt.bufPrint(&buf, "v{d}", .{phi_result_id}) catch "phi";
                        const name_copy = try alloc.dupe(u8, default_name);
                        try names.put(phi_result_id, name_copy);
                        phi_result = name_copy;
                    }
                    if (!already_declared) {
                        const phi_type = try wgslType(module, inst.words[1], names, arena);
                        const init_val = names.get(inst.words[3]) orelse "0";
                        try writeInd(w, indent); try w.print("var {s}: {s} = {s};\n", .{ phi_result.?, phi_type, init_val });
                    }
                    // Record phi update: result = value from second pair (words[5])
                    // If LoopMerge follows, this phi belongs to a new loop
                    var lm_follows = false;
                    {
                        var pk = i + 1;
                        while (pk < @min(i + 20, module.instructions.len)) : (pk += 1) {
                            if (module.instructions[pk].op == .LoopMerge) { lm_follows = true; break; }
                            if (module.instructions[pk].op == .FunctionEnd or module.instructions[pk].op == .Label) break;
                        }
                    }
                    if (lm_follows) {
                        pending_phi_start = phi_updates.items.len; // mark start BEFORE adding
                    }
                    if (inst.words.len >= 7) {
                        phi_updates.appendAssumeCapacity(.{ .result_id = inst.words[2], .value_id = inst.words[5] });
                    }
                    // Check if LoopMerge follows (within the next 30 instructions)
                    // Don't stop at Labels — loop header may have Labels between Phi and LoopMerge
                    var peek: usize = i + 1;
                    const peek_end = @min(i + 30, module.instructions.len);
                    while (peek < peek_end) : (peek += 1) {
                        if (module.instructions[peek].op == .LoopMerge) {
                            defer_active = true;
                            defer_start = i + 1;
                            break;
                        }
                        if (module.instructions[peek].op == .FunctionEnd) break;
                    }
                }
            },
            .BranchConditional => {
                if (inst.words.len >= 4) {
                    const condition = names.get(inst.words[1]) orelse "true";
                    const true_label = inst.words[2];
                    const false_label = inst.words[3];
                    // Check if this is a loop exit condition (BranchConditional in loop header)
                    if (in_loop and loop_merge_label != null and false_label == loop_merge_label.? and pending_merge == null) {
                        // Loop condition: if (!cond) { break; }
                        // Try to inline the condition expression for correctness
                        // (cached let values may be stale if they reference phi vars)
                        const inlined = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                        const cond_expr = inlined orelse condition;
                        if (inlined != null) {
                            dead_conditions.put(inst.words[1], {}) catch {};
                        }
                        try writeInd(w, indent); try w.print("if (!({s})) {{ break; }}\n", .{cond_expr});
                    } else if (pending_merge != null) {
                        const merge_label = pending_merge.?;
                        // Check if this is a break/continue inside a loop
                        const true_is_break = in_loop and loop_merge_label != null and true_label == loop_merge_label.?;
                        const false_is_break = in_loop and loop_merge_label != null and false_label == loop_merge_label.?;
                        const true_is_continue = in_loop and loop_continue_label != null and true_label == loop_continue_label.?;
                        const false_is_continue = in_loop and loop_continue_label != null and false_label == loop_continue_label.?;
                        if (true_is_break) {
                            // if (cond) { break; }
                            const inlined2 = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                            if (inlined2 != null) dead_conditions.put(inst.words[1], {}) catch {};
                            try writeInd(w, indent); try w.print("if ({s}) {{ break; }}\n", .{inlined2 orelse condition});
                            pending_merge = null;
                        } else if (false_is_break) {
                            // if (!(cond)) { break; }
                            const inlined3 = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                            if (inlined3 != null) dead_conditions.put(inst.words[1], {}) catch {};
                            try writeInd(w, indent); try w.print("if (!({s})) {{ break; }}\n", .{inlined3 orelse condition});
                            pending_merge = null;
                        } else if (true_is_continue) {
                            // Emit phi computation + updates before continue, inside the if block
                            // In SPIR-V, continue goes to continue block which computes phi values
                            // In WGSL, we must compute phi values before the continue keyword
                            try writeInd(w, indent); try w.print("if ({s}) {{\n", .{condition});
                            if (loop_stack.items.len > 0) {
                                const cur = loop_stack.items[loop_stack.items.len - 1];
                                // Scan forward for the continue block and emit phi-relevant computations
                                var ci: usize = i + 1;
                                while (ci < module.instructions.len) : (ci += 1) {
                                    const cinst = module.instructions[ci];
                                    if (cinst.op == .Label and cinst.words.len > 1 and cinst.words[1] == loop_continue_label.?) {
                                        // Found continue block — emit instructions until Branch back to header
                                        ci += 1;
                                        while (ci < module.instructions.len) : (ci += 1) {
                                            const cbinst = module.instructions[ci];
                                            if (cbinst.op == .Branch) break;
                                            if (cbinst.op == .Label) break;
                                            if (cbinst.words.len > 2) {
                                                const result_id = cbinst.words[2];
                                                var is_phi_val = false;
                                                var idx2: usize = cur.phi_start;
                                                while (idx2 < cur.phi_end) : (idx2 += 1) {
                                                    if (phi_updates.items[idx2].value_id == result_id) {
                                                        is_phi_val = true;
                                                        break;
                                                    }
                                                }
                                                if (is_phi_val) {
                                                    try emitSimpleInstruction(module, names, &inline_exprs, cbinst, w, alloc, arena, indent + 1);
                                                }
                                            }
                                        }
                                        break;
                                    }
                                    if (cinst.op == .FunctionEnd) break;
                                    // Don't stop at LoopMerge — nested loops may be between here and the continue block
                                }
                                // Emit the phi assignments
                                var idx: usize = cur.phi_start;
                                while (idx < cur.phi_end) : (idx += 1) {
                                    const pu = phi_updates.items[idx];
                                    const res_name = names.get(pu.result_id) orelse continue;
                                    const val_name = names.get(pu.value_id) orelse continue;
                                    try writeInd(w, indent + 1); try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                            }
                            try writeInd(w, indent + 1); try w.writeAll("continue;\n");
                            try writeInd(w, indent); try w.writeAll("}\n");
                            pending_merge = null;
                        } else if (false_is_continue) {
                            // Emit phi computation + updates before continue, inside the if block
                            try writeInd(w, indent); try w.print("if (!({s})) {{\n", .{condition});
                            if (loop_stack.items.len > 0) {
                                const cur = loop_stack.items[loop_stack.items.len - 1];
                                var ci: usize = i + 1;
                                while (ci < module.instructions.len) : (ci += 1) {
                                    const cinst = module.instructions[ci];
                                    if (cinst.op == .Label and cinst.words.len > 1 and cinst.words[1] == loop_continue_label.?) {
                                        ci += 1;
                                        while (ci < module.instructions.len) : (ci += 1) {
                                            const cbinst = module.instructions[ci];
                                            if (cbinst.op == .Branch) break;
                                            if (cbinst.op == .Label) break;
                                            if (cbinst.words.len > 2) {
                                                const result_id = cbinst.words[2];
                                                var is_phi_val = false;
                                                var idx2: usize = cur.phi_start;
                                                while (idx2 < cur.phi_end) : (idx2 += 1) {
                                                    if (phi_updates.items[idx2].value_id == result_id) {
                                                        is_phi_val = true;
                                                        break;
                                                    }
                                                }
                                                if (is_phi_val) {
                                                    try emitSimpleInstruction(module, names, &inline_exprs, cbinst, w, alloc, arena, indent + 1);
                                                }
                                            }
                                        }
                                        break;
                                    }
                                    if (cinst.op == .FunctionEnd) break;
                                    // Don't stop at LoopMerge — nested loops may be between here and the continue block
                                }
                                var idx: usize = cur.phi_start;
                                while (idx < cur.phi_end) : (idx += 1) {
                                    const pu = phi_updates.items[idx];
                                    const res_name = names.get(pu.result_id) orelse continue;
                                    const val_name = names.get(pu.value_id) orelse continue;
                                    try writeInd(w, indent + 1); try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                            }
                            try writeInd(w, indent + 1); try w.writeAll("continue;\n");
                            try writeInd(w, indent); try w.writeAll("}\n");
                            pending_merge = null;
                        } else {
                            // Regular if/else
                            try writeInd(w, indent); try w.print("if ({s}) {{\n", .{condition});
                            try merge_stack.append(arena, merge_label);
                            if_depth += 1;
                            indent += 1;
                            if (false_label != merge_label) {
                                pending_false_label = false_label;
                            } else {
                                pending_false_label = null;
                            }
                            pending_merge = null;
                        }
                    }
                }
            },
            .Branch => {
                if (inst.words.len > 1) {
                    const target = inst.words[1];
                    // Check for loop-related branches
                    if (in_loop) {
                        if (target == loop_header_label) {
                            // Back edge — emit phi updates for THIS loop only
                            if (loop_stack.items.len > 0) {
                                const cur = loop_stack.items[loop_stack.items.len - 1];
                                var idx: usize = cur.phi_start;
                                while (idx < cur.phi_end) : (idx += 1) {
                                    const pu = phi_updates.items[idx];
                                    const res_name = names.get(pu.result_id) orelse continue;
                                    const val_name = names.get(pu.value_id) orelse continue;
                                    try writeInd(w, indent); try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                            }
                            continue;
                        }
                        if (loop_continue_label != null and target == loop_continue_label.?) {
                            // Branch to continue block — skip
                            continue;
                        }
                    }
                    // Emit selection phi updates when branching to merge block
                    if (sel_phis.count() > 0) {
                        if (sel_phis.get(target)) |phi_list| {
                            // Find current predecessor label (previous Label instruction)
                            var cur_pred: ?u32 = null;
                            var li: usize = if (i > 0) i - 1 else 0;
                            while (li > func_idx) : (li -= 1) {
                                if (module.instructions[li].op == .Label and module.instructions[li].words.len > 1) {
                                    cur_pred = module.instructions[li].words[1];
                                    break;
                                }
                            }
                            if (cur_pred) |cp| {
                                for (phi_list.items) |sp| {
                                    if (sp.pred_label == cp) {
                                        const res_name = names.get(sp.result_id) orelse continue;
                                        const val_name = names.get(sp.value_id) orelse continue;
                                        try writeInd(w, indent); try w.print("{s} = {s};\n", .{ res_name, val_name });
                                    }
                                }
                            }
                        }
                    }
                    // When true branch ends and there's a false branch, emit } else {
                    if (if_depth > 0 and pending_false_label != null) {
                        if (merge_stack.items.len > 0) {
                            const cur_merge = merge_stack.items[merge_stack.items.len - 1];
                            if (target == cur_merge) {
                                indent -= 1;
                                try writeInd(w, indent); try w.writeAll("} else {");
                                try w.writeAll("\n");
                                indent += 1;
                                pending_false_label = null;
                            }
                        }
                    }
                }
            },
            .Label => {
                if (inst.words.len > 1) {
                    const label_id = inst.words[1];
                    // Check if this is the continue block label
                    if (in_loop and loop_continue_label != null and label_id == loop_continue_label.?) {
                        in_continue_block = true;
                        continue;
                    }
                    // Check if this label matches a loop merge (close loop)
                    if (loop_stack.items.len > 0) {
                        const top = loop_stack.items[loop_stack.items.len - 1];
                        if (label_id == top.merge) {
                            indent -= 1;
                            try writeInd(w, indent); try w.writeAll("}\n"); // close loop
                            _ = loop_stack.pop();
                            if (loop_stack.items.len > 0) {
                                const prev = loop_stack.items[loop_stack.items.len - 1];
                                loop_merge_label = prev.merge;
                                loop_continue_label = prev.cont;
                                loop_header_label = prev.header;
                                in_loop = true;
                            } else {
                                loop_merge_label = null;
                                loop_continue_label = null;
                                loop_header_label = null;
                                in_loop = false;
                            }
                            in_continue_block = false;
                            continue;
                        }
                    }
                    // Check if this label matches an if merge (close if)
                    if (if_depth > 0 and merge_stack.items.len > 0) {
                        const cur_merge = merge_stack.items[merge_stack.items.len - 1];
                        if (label_id == cur_merge) {
                            indent -= 1;
                            try writeInd(w, indent); try w.writeAll("}");
                            try w.writeAll("\n");
                            _ = merge_stack.pop();
                            if_depth -= 1;
                        }
                    }
                }
            },

            .Variable => {
                if (inst.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                    if (sc == .Function) {
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const vn = names.get(inst.words[2]) orelse "v";
                        try writeInd(w, indent); try w.print("var {s}: {s};\n", .{ vn, rt });
                    } else if (sc == .Private) {
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const vn = names.get(inst.words[2]) orelse "v";
                        try writeInd(w, indent); try w.print("var {s}: {s};\n", .{ vn, rt });
                    }
                    // Output/Input/Uniform/UniformConstant variables handled in entry point setup
                }
            },

            // Load
            .Load => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "var";
                const ptr_inst = getDef(module, inst.words[3]);
                var is_tex = false;
                var is_output_load = false;
                var is_input_load = false;
                if (ptr_inst) |pi| {
                    if (pi.op == .Variable and pi.words.len >= 4) {
                        const sc: spirv.StorageClass = @enumFromInt(pi.words[3]);
                        if (sc == .UniformConstant) {
                            const pt = getDef(module, pi.words[1]);
                            if (pt) |ptv| {
                                if (ptv.op == .TypePointer and ptv.words.len > 3) {
                                    const pe = getDef(module, ptv.words[3]);
                                    if (pe) |pev| {
                                        if (pev.op == .TypeSampler or pev.op == .TypeSampledImage or pev.op == .TypeImage) {
                                            is_tex = true;
                                        }
                                    }
                                }
                            }
                        }
                        if (sc == .Output) is_output_load = true;
                        if (sc == .Input) is_input_load = true;
                    }
                }
                if (is_tex) {
                    // Texture/sampler load: just propagate the variable name
                    const a = try alloc.dupe(u8, ptr);
                    if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                } else if (is_output_load) {
                    // Output variable load: just propagate the variable name
                    const a = try alloc.dupe(u8, ptr);
                    if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                } else if (is_input_load) {
                    // Input variable load: propagate the parameter name (e.g., gl_FragCoord)
                    const a = try alloc.dupe(u8, ptr);
                    if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                } else if (inline_loads.contains(inst.words[2])) {
                    // Single-use load: propagate name, skip declaration
                    // Re-resolve the pointer name in case AccessChain indices were updated
                    var resolved_ptr = ptr;
                    var resolved_allocated = false;
                    if (ptr_inst) |pi| {
                        if (pi.op == .AccessChain) {
                            const fresh_expr_opt: ?[]const u8 = buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc) catch null;
                            if (fresh_expr_opt) |fe0| {
                                var fresh_expr = fe0;
                                // If wrapped uniform array, append .x
                                if (std.mem.indexOf(u8, fresh_expr, "._wrapped_[") != null) {
                                    const with_x = try std.fmt.allocPrint(alloc, "{s}.x", .{fresh_expr});
                                    alloc.free(fresh_expr);
                                    fresh_expr = with_x;
                                }
                                if (!std.mem.eql(u8, fresh_expr, ptr)) {
                                    resolved_ptr = fresh_expr;
                                    resolved_allocated = true;
                                } else {
                                    // Same content as the existing ptr name — drop the fresh allocation.
                                    alloc.free(fresh_expr);
                                }
                            }
                        }
                    }
                    const a = try alloc.dupe(u8, resolved_ptr);
                    if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                    if (resolved_allocated) alloc.free(resolved_ptr);
                } else {
                    var expr: []const u8 = ptr;
                    var expr_allocated = false;
                    if (ptr_inst) |pi| {
                        if (pi.op == .AccessChain) {
                            expr = try buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc);
                            expr_allocated = true;
                            // If the base was renamed to include .values (wrapped uniform array), append .x
                            if (std.mem.indexOf(u8, expr, "._wrapped_[") != null) {
                                const with_x = try std.fmt.allocPrint(alloc, "{s}.x", .{expr});
                                alloc.free(expr);
                                expr = with_x;
                            }
                        }
                    }
                    const let_or_var: []const u8 = if (std.mem.startsWith(u8, result_name, "_inout_")) "var" else "let";
                    try writeInd(w, indent); try w.print("{s} {s}: {s} = {s};\n", .{ let_or_var, result_name, rt, expr });
                    if (expr_allocated) alloc.free(expr);
                }
            },

            // Store
            .Store => {
                // Skip store to output variable when doing direct return
                if (skip_store_target != null and inst.words[1] == skip_store_target.?) continue;
                // Skip stores to MRT output variables
                if (skip_store_targets != null and skip_store_targets.?.contains(inst.words[1])) continue;
                // Skip store to depth output (handled by FragmentOutput struct return)
                const ptr_name = names.get(inst.words[1]);
                if (ptr_name != null and std.mem.eql(u8, ptr_name.?, "gl_FragDepth")) continue;
                const ptr = names.get(inst.words[1]) orelse "var";
                const val = names.get(inst.words[2]) orelse "0";
                const ptr_inst = getDef(module, inst.words[1]);
                var expr: []const u8 = ptr;
                var expr_allocated = false;
                if (ptr_inst) |pi| {
                    if (pi.op == .AccessChain) {
                        expr = try buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc);
                        expr_allocated = true;
                    }
                }
                try writeInd(w, indent); try w.print("{s} = {s};\n", .{ expr, val });
                if (expr_allocated) alloc.free(expr);
            },

            // AccessChain
            .AccessChain => {
                const result_id = inst.words[2];
                const base_id = inst.words[3];
                const expr = try buildAccessExpr(module, names, base_id, inst.words[4..], alloc);
                if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
            },

            // CompositeConstruct
            .CompositeConstruct => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const num_comps = inst.words.len - 3;
                // Check if all components are the same (for scalar broadcast simplification)
                var all_same = true;
                var first_comp: ?[]const u8 = null;
                for (inst.words[3..], 0..) |comp_id, ci| {
                    const comp_name = names.get(comp_id) orelse "0";
                    if (ci == 0) {
                        first_comp = comp_name;
                    } else if (!std.mem.eql(u8, comp_name, first_comp.?)) {
                        all_same = false;
                        break;
                    }
                }
                if (all_same and num_comps > 1 and first_comp != null) {
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, first_comp.? });
                } else {
                    // Check for leading sequential extracts from the same source
                    // e.g., vec4f(v.x, v.y, v.z, 1.0) → vec4f(v, 1.0) or vec4f(v.xyz, 1.0)
                    var lead_source: ?u32 = null;
                    var lead_count: usize = 0;
                    for (inst.words[3..], 0..) |comp_id, ci| {
                        const comp_def = getDef(module, comp_id);
                        if (comp_def) |cd| {
                            if (cd.op == .CompositeExtract and cd.words.len > 4) {
                                if (ci == 0) {
                                    lead_source = cd.words[3];
                                    lead_count = 1;
                                } else if (cd.words[3] == lead_source.? and cd.words[4] == ci) {
                                    lead_count += 1;
                                } else {
                                    break;
                                }
                            } else {
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                    // Check if source is a struct — struct extracts shouldn't use swizzle notation
                    var src_is_struct = false;
                    if (lead_source) |ls| {
                        const src_type_for_swizzle = resolveTypeOf(module, ls);
                        if (src_type_for_swizzle) |st| {
                            const st_def2 = getDef(module, st);
                            if (st_def2) |sd3| {
                                if (sd3.op == .TypeStruct) src_is_struct = true;
                            }
                        }
                    }
                    if (lead_count >= 2 and lead_source != null and !src_is_struct) {
                        // Emit with leading source aggregated
                        var parts = std.ArrayList(u8).initCapacity(arena, 128) catch return;
                        defer parts.deinit(arena);
                        const src_name = names.get(lead_source.?) orelse "v";
                        // Check if lead_count matches the full source vector size → use source directly
                        const src_type = resolveTypeOf(module, lead_source.?);
                        var src_num_comp: usize = 0;
                        if (src_type) |st| {
                            const st_def = getDef(module, st);
                            if (st_def) |sd| {
                                if (sd.op == .TypeVector and sd.words.len > 3) src_num_comp = sd.words[3];
                            }
                        }
                        if (lead_count == src_num_comp) {
                            try parts.appendSlice(arena, src_name);
                        } else {
                            try parts.appendSlice(arena, src_name);
                            try parts.append(arena, '.');
                            const xyzw: []const u8 = "xyzw";
                            for (0..lead_count) |si| {
                                if (si < 4) try parts.append(arena, xyzw[si]);
                            }
                        }
                        // Append remaining non-extract components
                        for (inst.words[3 + lead_count ..], 0..) |comp_id, ci| {
                            _ = ci;
                            try parts.appendSlice(arena, ", ");
                            const comp_name = names.get(comp_id) orelse "0";
                            try parts.appendSlice(arena, comp_name);
                        }
                        try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, parts.items });
                    } else {
                        // General case: emit all components
                        var parts = std.ArrayList(u8).initCapacity(alloc, 128) catch return;
                        defer parts.deinit(alloc);
                        for (inst.words[3..], 0..) |comp_id, ci| {
                            if (ci > 0) try parts.appendSlice(alloc, ", ");
                            const comp_name = names.get(comp_id) orelse "0";
                            try parts.appendSlice(alloc, comp_name);
                        }
                        try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, parts.items });
                    }
                }
            },

            // CompositeExtract
            .CompositeExtract => {
                // Skip dead extracts or inlined extracts (name was propagated to use site)
                if (dead_extracts.contains(inst.words[2]) or inline_loads.contains(inst.words[2])) continue;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const composite = names.get(inst.words[3]) orelse "c";
                // Build type-aware access expression
                var expr = std.ArrayList(u8).initCapacity(alloc, 64) catch return;
                defer expr.deinit(alloc);
                try expr.appendSlice(alloc, composite);
                // Resolve composite type for member name resolution
                var current_type: ?u32 = resolveTypeOf(module, inst.words[3]);
                if (current_type == null) {
                    // Fallback: look at the defining instruction's result type
                    const comp_def = getDef(module, inst.words[3]);
                    if (comp_def) |cd| {
                        if (cd.words.len > 1) {
                            // Check if result type is a pointer — resolve pointee
                            const rt_inst = getDef(module, cd.words[1]);
                            if (rt_inst) |rti| {
                                if (rti.op == .TypePointer and rti.words.len > 3) {
                                    current_type = rti.words[3];
                                } else {
                                    current_type = cd.words[1];
                                }
                            }
                        }
                    }
                }
                for (inst.words[4..]) |idx| {
                    if (current_type) |ct| {
                        const ct_inst = getDef(module, ct);
                        if (ct_inst) |cti| {
                            if (cti.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(module, ct, idx, &mname_buf);
                                try expr.print(alloc, ".{s}", .{mname});
                                if (idx + 2 < cti.words.len) current_type = cti.words[idx + 2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeVector) {
                                const sw = switch (idx) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" };
                                try expr.appendSlice(alloc, sw);
                                if (cti.words.len > 2) current_type = cti.words[2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeMatrix or cti.op == .TypeArray) {
                                try expr.print(alloc, "[{d}]", .{idx});
                                if (cti.words.len > 2) current_type = cti.words[2] else current_type = null;
                                continue;
                            }
                        }
                    }
                    // Fallback: array index
                    try expr.print(alloc, "[{d}]", .{idx});
                }
                try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, expr.items });
            },

            // CopyObject
            .CopyObject => {
                // Just propagate the name, don't create a local var
                if (inst.words.len > 3) {
                    const val = names.get(inst.words[3]) orelse "0";
                    const a = try alloc.dupe(u8, val);
                    if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                }
            },

            // VectorShuffle
            .VectorShuffle => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const v1 = names.get(inst.words[3]) orelse "v1";
                const v2 = names.get(inst.words[4]) orelse "v2";
                // Get component count of first vector to determine single-source swizzle
                const v1_type = getDef(module, inst.words[3]);
                var v1_count: u32 = 4; // default to vec4
                if (v1_type) |vt| blk: {
                    if (vt.op == .Load or vt.op == .AccessChain) {
                        // Resolve through load/accesschain to get the actual type
                        if (vt.words.len > 1) {
                            const inner_type = getDef(module, vt.words[1]);
                            if (inner_type) |it| {
                                if (it.op == .TypeVector and it.words.len > 3) {
                                    v1_count = it.words[3];
                                    break :blk;
                                }
                            }
                        }
                    }
                    // Check if v1 instruction has a type we can use
                    if (vt.op == .TypeVector and vt.words.len > 3) {
                        v1_count = vt.words[3];
                    } else if (vt.words.len > 1) {
                        const t = getDef(module, vt.words[1]);
                        if (t) |ti| {
                            if (ti.op == .TypeVector and ti.words.len > 3) {
                                v1_count = ti.words[3];
                            }
                        }
                    }
                }
                // Check if all components come from the same source vector (single-source swizzle)
                var single_source = true;
                for (inst.words[5..]) |idx| {
                    if (idx >= v1_count) { single_source = false; break; }
                }
                if (single_source) {
                    // All from v1 — emit as v1.xyzw swizzle
                    var sw = std.ArrayList(u8).initCapacity(arena, 5) catch return;
                    defer sw.deinit(arena);
                    const chars = "xyzw";
                    for (inst.words[5..]) |idx| {
                        if (idx < 4) try sw.append(arena, chars[idx]);
                    }
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s}.{s};\n", .{ result_name, rt, v1, sw.items });
                } else {
                    // Mixed sources — construct from components
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s}(", .{ result_name, rt, rt });
                    var first = true;
                    for (inst.words[5..]) |idx| {
                        if (!first) try w.writeAll(", ");
                        first = false;
                        const src = if (idx < v1_count) v1 else v2;
                        const comp = idx % v1_count;
                        const sw = switch (comp) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" };
                        try w.print("{s}{s}", .{ src, sw });
                    }
                    try w.writeAll(");\n");
                }
            },

            // Arithmetic
            .FAdd, .IAdd => try emitBinOp(module, names, &inline_exprs, inst, "+", w, arena, indent),
            .FSub, .ISub => try emitBinOp(module, names, &inline_exprs, inst, "-", w, arena, indent),
            .FMul, .IMul => try emitBinOp(module, names, &inline_exprs, inst, "*", w, arena, indent),
            .FDiv, .SDiv, .UDiv => try emitBinOp(module, names, &inline_exprs, inst, "/", w, arena, indent),
            .FMod => try emitBinOp(module, names, &inline_exprs, inst, "%", w, arena, indent),
            .UMod, .SRem, .SMod, .FRem => try emitBinOp(module, names, &inline_exprs, inst, "%", w, arena, indent),
            .ShiftLeftLogical, .ShiftRightLogical => {
                // WGSL requires shift amount to be u32
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const lhs_raw = resolveOperandExpr(module, names, &inline_exprs, inst.words[3], arena, 0);
                const rhs_raw = resolveOperandExpr(module, names, &inline_exprs, inst.words[4], arena, 0);
                const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
                const op_str: []const u8 = if (inst.op == .ShiftLeftLogical) "<<" else ">>";
                try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s} {s} u32({s});\n", .{ result_name, rt, lhs, op_str, rhs_raw });
            },
            .ShiftRightArithmetic => try emitBinOp(module, names, &inline_exprs, inst, ">>", w, arena, indent),
            .FNegate, .SNegate => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent); try w.print("let {s}: {s} = -{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .VectorTimesScalar, .MatrixTimesScalar => try emitBinOp(module, names, &inline_exprs, inst, "*", w, arena, indent),
            .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => {
                // WGSL uses mul() — wait, WGSL doesn't have mul(). Use matrix multiplication operator *
                try emitBinOp(module, names, &inline_exprs, inst, "*", w, arena, indent);
            },

            // Dot product
            .Dot => try emitCall(module, names, inst, "dot", w, arena, indent),

            // Comparisons
            .FOrdEqual, .IEqual => try emitBinOp(module, names, &inline_exprs, inst, "==", w, arena, indent),
            .FOrdNotEqual, .INotEqual => try emitBinOp(module, names, &inline_exprs, inst, "!=", w, arena, indent),
            .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(module, names, &inline_exprs, inst, "<", w, arena, indent),
            .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(module, names, &inline_exprs, inst, ">", w, arena, indent),
            .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(module, names, &inline_exprs, inst, "<=", w, arena, indent),
            .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(module, names, &inline_exprs, inst, ">=", w, arena, indent),

            // Logical
            .LogicalOr => try emitBinOp(module, names, &inline_exprs, inst, "||", w, arena, indent),
            .LogicalAnd => try emitBinOp(module, names, &inline_exprs, inst, "&&", w, arena, indent),
            .LogicalNot => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent); try w.print("let {s}: {s} = !{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "true" });
            },

            // Select (ternary)
            .Select => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const cond = names.get(inst.words[3]) orelse "c";
                const true_val = names.get(inst.words[4]) orelse "t";
                const false_val = names.get(inst.words[5]) orelse "f";
                // WGSL select() only works with scalars and vectors, not structs
                if (std.mem.startsWith(u8, rt, "struct") or std.mem.containsAtLeast(u8, rt, 1, "Struct") or
                    (inst.words.len > 1 and isStructType(module, inst.words[1])))
                {
                    try writeInd(w, indent); try w.print("var {s}: {s};\n", .{ result_name, rt });
                    try writeInd(w, indent); try w.print("if ({s}) {{\n", .{cond});
                    try writeInd(w, indent + 1); try w.print("{s} = {s};\n", .{ result_name, true_val });
                    try writeInd(w, indent); try w.writeAll("} else {\n");
                    try writeInd(w, indent + 1); try w.print("{s} = {s};\n", .{ result_name, false_val });
                    try writeInd(w, indent); try w.writeAll("}\n");
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
                }
            },

            // Conversions
            .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
            .UConvert, .SConvert, .FConvert => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const val = names.get(inst.words[3]) orelse "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, val });
            },
            .Bitcast => {
                // Bitcast in WGSL: bitcast<T>(value)
                // If source and dest types match, it's a no-op — just assign the value
                const result_name = names.get(inst.words[2]) orelse "v";
                const val = names.get(inst.words[3]) orelse "0";
                const rt = try wgslType(module, inst.words[1], names, arena);
                // Check if operand type matches result type (same-type bitcast is no-op)
                const operand_type_id = getTypeOf(module, inst.words[3]);
                const is_same_type = if (operand_type_id) |otid| blk: {
                    const src_type = try wgslType(module, otid, names, arena);
                    break :blk std.mem.eql(u8, src_type, rt);
                } else false;
                if (is_same_type) {
                    // Same-type bitcast: just assign the value directly
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, val });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = bitcast<{s}>({s});\n", .{ result_name, rt, rt, val });
                }
            },

            // Texture sampling
            .ImageSampleImplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                // Get texture name directly from combined sampler ID
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureSample({s}, {s}_sampler, {s});\n", .{ result_name, rt, tex_name, tex_name, coord });
            },

            .ImageSampleExplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lod });
            },

            .ImageSampleDrefImplicitLod => {
                try emitDepthCompare(module, names, w, indent, arena, inst, "textureSampleCompare");
            },

            .ImageSampleDrefExplicitLod => {
                // WGSL textureSampleCompareLevel always samples mip level 0 and
                // takes NO explicit level argument — the SPIR-V Lod operand is
                // dropped (it is 0 for the common textureLod(shadow, …, 0.0)).
                try emitDepthCompare(module, names, w, indent, arena, inst, "textureSampleCompareLevel");
            },

            .ImageFetch => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const si = names.get(inst.words[3]) orelse "tex";
                const coord = names.get(inst.words[4]) orelse "uv";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureLoad({s}, {s});\n", .{ result_name, rt, si, coord });
            },

            // Return
            .Return => {
                if (inout_return) |ret_name| {
                    try writeInd(w, indent); try w.print("return {s};\n", .{ret_name});
                }
                // Otherwise: void return in entry function — handled by wrapper
            },

            // ExtInst (GLSL.std.450)
            .ExtInst => {
                if (inst.words.len > 4) {
                    const set_id = inst.words[3];
                    const instruction = inst.words[4];
                    // Check if this is GLSL.std.450 (set_id should match)
                    const ext_name = names.get(set_id) orelse "";
                    if (std.mem.indexOf(u8, ext_name, "GLSL.std.450") != null or true) {
                        // instruction is the GLSL opcode
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const result_name = names.get(inst.words[2]) orelse "v";
                        // Shared name mapping (single source of truth; honest-errors unmapped ops).
                        const func_name = try glslStd450WgslName(instruction);
                        // Build args
                        var args = std.ArrayList(u8).initCapacity(arena, 128) catch return;
                        defer args.deinit(arena);
                        for (inst.words[5..], 0..) |arg_id, ai| {
                            if (ai > 0) try args.appendSlice(arena, ", ");
                            try args.appendSlice(arena, names.get(arg_id) orelse "0");
                        }
                        // Map GLSL.std.450 names to WGSL equivalents
                        const wgsl_name = if (std.mem.eql(u8, func_name, "faceForward"))
                            "faceForward"
                        else if (std.mem.eql(u8, func_name, "findILsb"))
                            "firstTrailingBit"
                        else if (std.mem.eql(u8, func_name, "findSMsb") or std.mem.eql(u8, func_name, "findUMsb"))
                            "firstLeadingBit"
                        else if (std.mem.eql(u8, func_name, "modf"))
                            "frexp" // WGSL frexp returns struct
                        else
                            func_name;
                        try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, wgsl_name, args.items });
                    }
                }
            },

            // Function call
            .FunctionCall => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const func_id = inst.words[3];
                const func_name = names.get(func_id) orelse "func";

                // Check if the callee has inout params by examining its function type
                var callee_inout_arg_indices = std.ArrayList(usize).initCapacity(arena, 4) catch return;
                const func_def = getDef(module, func_id);
                if (func_def) |fd| {
                    if (fd.op == .Function and fd.words.len > 4) {
                        const ftype_id = fd.words[4];
                        const ft = getDef(module, ftype_id);
                        if (ft) |fti| {
                            if (fti.op == .TypeFunction) {
                                for (fti.words[3..], 0..) |ptype_id, pidx| {
                                    const pt = getDef(module, ptype_id);
                                    if (pt) |pti| {
                                        if (pti.op == .TypePointer and pti.words.len > 3) {
                                            const sc: spirv.StorageClass = @enumFromInt(pti.words[2]);
                                            if (sc == .Function) {
                                                try callee_inout_arg_indices.append(arena, pidx);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
                defer args.deinit(arena);
                for (inst.words[4..], 0..) |arg_id, ai| {
                    if (ai > 0) try args.appendSlice(arena, ", ");
                    try args.appendSlice(arena, names.get(arg_id) orelse "0");
                }

                if (callee_inout_arg_indices.items.len == 1 and std.mem.eql(u8, rt, "void")) {
                    // Void function with single inout param: caller reassigns
                    // e.g., v16 = out_test_0(40, v16);
                    const inout_idx = callee_inout_arg_indices.items[0];
                    if (inst.words.len > 4 + inout_idx) {
                        const inout_arg_id = inst.words[4 + inout_idx];
                        const inout_arg_name = names.get(inout_arg_id) orelse "_out";
                        try writeInd(w, indent);
                        try w.print("{s} = {s}({s});\n", .{ inout_arg_name, func_name, args.items });
                    } else {
                        try writeInd(w, indent); try w.print("{s}({s});\n", .{ func_name, args.items });
                    }
                } else if (std.mem.eql(u8, rt, "void")) {
                    try writeInd(w, indent); try w.print("{s}({s});\n", .{ func_name, args.items });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                }
            },

            // Bitwise
            .BitwiseOr => try emitBinOp(module, names, &inline_exprs, inst, "|", w, arena, indent),
            .BitwiseXor => try emitBinOp(module, names, &inline_exprs, inst, "^", w, arena, indent),
            .BitwiseAnd => try emitBinOp(module, names, &inline_exprs, inst, "&", w, arena, indent),
            .Not => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent); try w.print("let {s}: {s} = ~{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .BitReverse => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent); try w.print("let {s}: {s} = reverseBits({s});\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .BitCount => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent); try w.print("let {s}: {s} = countOneBits({s});\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            // SPIR-V bitfield ops: WGSL has insertBits(e, newbits, offset, count)
            // and extractBits(e, offset, count). The S/U variants of extract
            // both map to extractBits — WGSL picks signed vs unsigned from
            // the argument type (i32 vs u32). offset / count must be u32 in WGSL.
            .BitFieldInsert => {
                if (inst.words.len < 7) continue;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const base = names.get(inst.words[3]) orelse "0";
                const insert = names.get(inst.words[4]) orelse "0";
                const offset = names.get(inst.words[5]) orelse "0u";
                const count = names.get(inst.words[6]) orelse "0u";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = insertBits({s}, {s}, u32({s}), u32({s}));\n", .{ rn, rt, base, insert, offset, count });
            },
            .BitFieldSExtract, .BitFieldUExtract => {
                if (inst.words.len < 6) continue;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const base = names.get(inst.words[3]) orelse "0";
                const offset = names.get(inst.words[4]) orelse "0u";
                const count = names.get(inst.words[5]) orelse "0u";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = extractBits({s}, u32({s}), u32({s}));\n", .{ rn, rt, base, offset, count });
            },

            // Derivatives
            .DPdx => try emitCall(module, names, inst, "dpdx", w, arena, indent),
            .DPdy => try emitCall(module, names, inst, "dpdy", w, arena, indent),
            .DPdxCoarse => try emitCall(module, names, inst, "dpdxCoarse", w, arena, indent),
            .DPdyCoarse => try emitCall(module, names, inst, "dpdyCoarse", w, arena, indent),
            .FwidthCoarse => try emitCall(module, names, inst, "fwidthCoarse", w, arena, indent),
            .Fwidth => try emitCall(module, names, inst, "fwidth", w, arena, indent),

            // Subgroup operations (WGSL subgroup functions)
            .SubgroupAllKHR, .GroupNonUniformAll => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "true" else "true";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupAll({s});\n", .{ rn, rt, val });
            },
            .SubgroupAnyKHR, .GroupNonUniformAny => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "false" else "false";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupAny({s});\n", .{ rn, rt, val });
            },
            .GroupNonUniformElect => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupElect();\n", .{ rn, rt });
            },
            .GroupNonUniformBroadcast => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                const id = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupBroadcast({s}, {s});\n", .{ rn, rt, val, id });
            },
            .GroupNonUniformBroadcastFirst => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupBroadcastFirst({s});\n", .{ rn, rt, val });
            },
            .GroupNonUniformBallot => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "false" else "false";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupBallot({s});\n", .{ rn, rt, val });
            },
            .GroupNonUniformShuffle => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                const id = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupShuffle({s}, {s});\n", .{ rn, rt, val, id });
            },
            .GroupNonUniformShuffleXor => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                const mask = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupShuffleXor({s}, {s});\n", .{ rn, rt, val, mask });
            },
            .GroupNonUniformShuffleUp => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                const delta = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupShuffleUp({s}, {s});\n", .{ rn, rt, val, delta });
            },
            .GroupNonUniformShuffleDown => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
                const delta = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = subgroupShuffleDown({s}, {s});\n", .{ rn, rt, val, delta });
            },
            // GroupNonUniform arithmetic: IAdd, FAdd, IMul, FMul
            .GroupNonUniformIAdd, .GroupNonUniformFAdd => {
                try emitSubgroupArith(module, names, inst, "Add", w, arena, indent);
            },
            .GroupNonUniformIMul, .GroupNonUniformFMul => {
                try emitSubgroupArith(module, names, inst, "Mul", w, arena, indent);
            },
            .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => {
                try emitSubgroupArith(module, names, inst, "Min", w, arena, indent);
            },
            .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => {
                try emitSubgroupArith(module, names, inst, "Max", w, arena, indent);
            },
            .GroupNonUniformBitwiseAnd, .GroupNonUniformLogicalAnd => {
                try emitSubgroupArith(module, names, inst, "And", w, arena, indent);
            },
            .GroupNonUniformBitwiseOr, .GroupNonUniformLogicalOr => {
                try emitSubgroupArith(module, names, inst, "Or", w, arena, indent);
            },
            .GroupNonUniformBitwiseXor => {
                try emitSubgroupArith(module, names, inst, "Xor", w, arena, indent);
            },

            // Return value
            .ReturnValue => {
                const val = names.get(inst.words[1]) orelse "v";
                try writeInd(w, indent); try w.print("return {s};\n", .{val});
            },

            // Kill (discard in fragment)
            .Kill => {
                try writeInd(w, indent); try w.writeAll("discard;\n");
            },

            // Unreachable
            .Unreachable => {
                try writeInd(w, indent); try w.writeAll("unreachable;\n");
            },

            // Undef — zero-initialize
            .Undef => {
                if (inst.words.len > 2) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const rn = names.get(inst.words[2]) orelse "v";
                    try writeInd(w, indent); try w.print("var {s}: {s}; // undef\n", .{ rn, rt });
                }
            },

            // Nop
            .Nop => {},

            // All/Any (vector boolean reduction)
            .All => try emitCall(module, names, inst, "all", w, arena, indent),
            .Any => try emitCall(module, names, inst, "any", w, arena, indent),

            // IsInf/IsNan
            .IsInf => try emitCall(module, names, inst, "isinf", w, arena, indent),
            .IsNan => try emitCall(module, names, inst, "isnan", w, arena, indent),

            // CompositeInsert
            .CompositeInsert => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const composite = names.get(inst.words[3]) orelse "c";
                const object = names.get(inst.words[4]) orelse "o";
                // Build access chain from indices with type-aware member names
                var access = std.ArrayList(u8).initCapacity(arena, 64) catch return;
                defer access.deinit(arena);
                // Walk the type chain to resolve struct member names
                var current_type: ?u32 = if (inst.words.len > 1) blk: {
                    // result type is the composite type
                    const ti = getDef(module, inst.words[1]);
                    break :blk if (ti) |t| t.words[1] else null;
                } else null;
                for (inst.words[5..]) |idx| {
                    if (current_type) |ct| {
                        const ct_inst = getDef(module, ct);
                        if (ct_inst) |cti| {
                            if (cti.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = getMemberName(module, ct, idx, &mname_buf);
                                try access.print(arena, ".{s}", .{mname});
                                // Walk to member type
                                if (idx + 2 < cti.words.len) current_type = cti.words[idx + 2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeVector) {
                                const sw = switch (idx) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" };
                                try access.appendSlice(arena, sw);
                                if (cti.words.len > 2) current_type = cti.words[2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeMatrix) {
                                try access.print(arena, "[{d}]", .{idx});
                                if (cti.words.len > 2) current_type = cti.words[2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeArray) {
                                try access.print(arena, "[{d}]", .{idx});
                                if (cti.words.len > 2) current_type = cti.words[2] else current_type = null;
                                continue;
                            }
                        }
                    }
                    // Fallback: use vector swizzle
                    const sw = switch (idx) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => "[0]" };
                    try access.appendSlice(arena, sw);
                }
                // First copy composite, then set the field
                try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, composite });
                try writeInd(w, indent); try w.print("{s}{s} = {s};\n", .{ result_name, access.items, object });
            },

            // VectorExtractDynamic
            .VectorExtractDynamic => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const vector = names.get(inst.words[3]) orelse "vec";
                const index = names.get(inst.words[4]) orelse "i";
                try writeInd(w, indent); try w.print("let {s}: {s} = {s}[{s}];\n", .{ result_name, rt, vector, index });
            },

            // Transpose
            .Transpose => try emitCall(module, names, inst, "transpose", w, arena, indent),

            // SampledImage — just pass through the image ID
            .SampledImage => {
                if (inst.words.len > 4) {
                    const result_id = inst.words[2];
                    const image_id = inst.words[3];
                    const image_name = names.get(image_id) orelse "tex";
                    // Store the image name as the result
                    if (try names.fetchPut(result_id, try alloc.dupe(u8, image_name))) |old| {
                        alloc.free(old.value);
                    }
                }
            },

            // OpImage — extract image from sampled image
            .OpImage => {
                if (inst.words.len > 3) {
                    const result_id = inst.words[2];
                    const image_name = names.get(inst.words[3]) orelse "tex";
                    if (try names.fetchPut(result_id, try alloc.dupe(u8, image_name))) |old| {
                        alloc.free(old.value);
                    }
                }
            },

            // ImageQuerySize
            .ImageQuerySize => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureDimensions({s});\n", .{ result_name, rt, image });
            },

            // ImageQuerySizeLod
            .ImageQuerySizeLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                const lod = names.get(inst.words[4]) orelse "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureDimensions({s}, {s});\n", .{ result_name, rt, image, lod });
            },

            // ImageQueryLevels
            .ImageQueryLevels => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureNumLevels({s});\n", .{ result_name, rt, image });
            },

            // ImageQuerySamples
            .ImageQuerySamples => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureNumSamples({s});\n", .{ result_name, rt, image });
            },

            // ImageQueryLod
            .ImageQueryLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const si_inst = getDef(module, inst.words[3]);
                var tex_name: []const u8 = "tex";
                if (si_inst) |sii| {
                    if (sii.op == .SampledImage and sii.words.len > 3) {
                        tex_name = names.get(sii.words[2]) orelse "tex";
                    } else {
                        tex_name = names.get(inst.words[3]) orelse "tex";
                    }
                }
                const coord = if (inst.words.len > 4) names.get(inst.words[4]) orelse "uv" else "uv";
                try writeInd(w, indent); try w.print("let {s}: {s} = vec2f(f32(textureQueryLod({s}, {s})), 0.0);\n", .{ result_name, rt, tex_name, coord });
            },

            // ImageGather
            .ImageGather => {
                // textureGatherOffsets lowers to OpImageGather with the
                // ConstOffsets image operand (mask bit 0x20 at word[6], the
                // 4-offset array id at word[7]). WGSL's textureGather takes no
                // per-texel offset array, so emitting a plain textureGather here
                // would SILENTLY DROP the offsets (silent-wrong). Fail loudly
                // instead; per-texel emulation (4 gathers) is a follow-up.
                if (inst.words.len > 6 and (inst.words[6] & 0x20) != 0) {
                    return error.UnsupportedImageOperands;
                }
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const si_inst = getDef(module, inst.words[3]);
                var tex_name: []const u8 = "tex";
                if (si_inst) |sii| {
                    if (sii.op == .SampledImage and sii.words.len > 3) {
                        tex_name = names.get(sii.words[2]) orelse "tex";
                    } else {
                        tex_name = names.get(inst.words[3]) orelse "tex";
                    }
                }
                const coord = names.get(inst.words[4]) orelse "uv";
                const component = names.get(inst.words[5]) orelse "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureGather({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, component });
            },

            // ImageDrefGather — depth comparison gather
            .ImageDrefGather => {
                // textureGatherCompare on an ARRAYED depth texture needs a
                // separate array_index argument the gather path does not yet
                // build; fail loudly rather than emit wrong-arity WGSL. (The
                // compare-SAMPLE path DOES support arrays — see emitDepthCompare.)
                if (depthCompareShape(module, inst.words[3]).arrayed) return error.UnsupportedDepthArrayTexture;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const si_inst = getDef(module, inst.words[3]);
                var tex_name: []const u8 = "tex";
                if (si_inst) |sii| {
                    if (sii.op == .SampledImage and sii.words.len > 3) {
                        tex_name = names.get(sii.words[2]) orelse "tex";
                    } else {
                        tex_name = names.get(inst.words[3]) orelse "tex";
                    }
                }
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureGatherCompare({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref });
            },

            // ImageSampleProjImplicitLod — projective texture sampling
            .ImageSampleProjImplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                // Projective: divide xy by w (component 3)
                try writeInd(w, indent); try w.print("let {s}: {s} = textureSample({s}, {s}_sampler, {s}.xy / {s}.w);\n", .{ result_name, rt, tex_name, tex_name, coord, coord });
            },

            // ReadClockKHR — shader clock
            .ReadClockKHR => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                try writeInd(w, indent); try w.print("let {s}: {s} = 0u; // ReadClockKHR stub\n", .{ result_name, rt });
            },

            // ImageRead (storage image load)
            .ImageRead => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "img";
                const coord = names.get(inst.words[4]) orelse "uv";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureLoad({s}, {s});\n", .{ result_name, rt, image, coord });
            },

            // ImageWrite (storage image store)
            .ImageWrite => {
                const image = names.get(inst.words[1]) orelse "img";
                const coord = names.get(inst.words[2]) orelse "uv";
                const texel = names.get(inst.words[3]) orelse "color";
                try writeInd(w, indent); try w.print("textureStore({s}, {s}, {s});\n", .{ image, coord, texel });
            },

            // ImageTexelPointer
            .ImageTexelPointer => {
                if (inst.words.len > 4) {
                    const result_id = inst.words[2];
                    const image = names.get(inst.words[3]) orelse "img";
                    const coord = names.get(inst.words[4]) orelse "uv";
                    const expr = try std.fmt.allocPrint(alloc, "textureLoad({s}, {s})", .{ image, coord });
                    if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
                }
            },

            // CopyLogical
            .CopyLogical => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const val = names.get(inst.words[3]) orelse "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, val });
            },

            // CopyMemory
            .CopyMemory => {
                if (inst.words.len >= 3) {
                    const dst = names.get(inst.words[1]) orelse "dst";
                    const src = names.get(inst.words[2]) orelse "src";
                    try writeInd(w, indent); try w.print("{s} = {s};\n", .{ dst, src });
                }
            },

            // ControlBarrier / MemoryBarrier
            .ControlBarrier => {
                try writeInd(w, indent); try w.writeAll("workgroupBarrier();\n");
            },
            .MemoryBarrier => {
                try writeInd(w, indent); try w.writeAll("storageBarrier();\n");
            },

            // Atomic operations
            .AtomicIAdd => try emitAtomicBinOp(module, names, inst, "Add", w, arena, indent),
            .AtomicISub => try emitAtomicBinOp(module, names, inst, "Sub", w, arena, indent),
            .AtomicAnd => try emitAtomicBinOp(module, names, inst, "And", w, arena, indent),
            .AtomicOr => try emitAtomicBinOp(module, names, inst, "Or", w, arena, indent),
            .AtomicXor => try emitAtomicBinOp(module, names, inst, "Xor", w, arena, indent),
            .AtomicUMin, .AtomicSMin => try emitAtomicBinOp(module, names, inst, "Min", w, arena, indent),
            .AtomicUMax, .AtomicSMax => try emitAtomicBinOp(module, names, inst, "Max", w, arena, indent),
            .AtomicFAddEXT => try emitAtomicBinOp(module, names, inst, "Add", w, arena, indent),
            .AtomicExchange => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                const val = names.get(inst.words[4]) orelse "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = atomicExchange(&{s}, {s});\n", .{ rn, rt, ptr, val });
            },
            .AtomicCompareExchange => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                // words[4] = scope, words[5] = memory semantics
                const cmp = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = atomicCompareExchangeWeak(&{s}, {s}, {s}).old_value;\n", .{ rn, rt, ptr, cmp, val });
            },

            else => {
                // Try to handle as a simple assignment
                if (inst.words.len > 2) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const rn = names.get(inst.words[2]) orelse "v";
                    try writeInd(w, indent); try w.print("// unhandled op {d}\n", .{@intFromEnum(inst.op)});
                    try writeInd(w, indent); try w.print("var {s}: {s};\n", .{ rn, rt });
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Emit helpers
// ---------------------------------------------------------------------------

fn emitBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    // Wrap compound expressions in parens for correct precedence
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    // Avoid division by literal zero (naga evaluates compile-time)
    if (std.mem.eql(u8, op, "/") and isLiteralZero(rhs)) {
        try writeIndentStatic(w, indent); try w.print("let {s}: {s} = 0.0;\n", .{ result_name, rt });
        return;
    }
    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op, rhs });
}

// Check if a string is a compound expression (contains operators at depth 0)
fn isLiteralZero(s: []const u8) bool {
    return std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "0.0") or std.mem.eql(u8, s, "0.0.0");
}

fn isCompoundExpr(s: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0 and i > 0) {
            // Check for " op " pattern (operator surrounded by spaces)
            if (c == ' ') {
                // Look ahead for operator and space: " + ", " - ", etc.
                if (i + 2 < s.len and s[i + 2] == ' ') {
                    const op_char = s[i + 1];
                    if (op_char == '+' or op_char == '-' or op_char == '*' or op_char == '/' or op_char == '%' or
                        op_char == '<' or op_char == '>' or op_char == '=' or op_char == '!' or
                        op_char == '&' or op_char == '|' or op_char == '^')
                    {
                        return true;
                    }
                    // Two-char ops: <=, >=, ==, !=, <<, >>
                    if (i + 3 < s.len and s[i + 3] == ' ') {
                        const op_pair = s[i + 1..i + 3];
                        if (std.mem.eql(u8, op_pair, "<=") or std.mem.eql(u8, op_pair, ">=") or
                            std.mem.eql(u8, op_pair, "==") or std.mem.eql(u8, op_pair, "!=") or
                            std.mem.eql(u8, op_pair, "<<") or std.mem.eql(u8, op_pair, ">>"))
                        {
                            return true;
                        }
                    }
                    // "or" and "and" keywords
                    if (i + 3 < s.len and s[i + 3] == ' ') {
                        const kw = s[i + 1..i + 3];
                        if (std.mem.eql(u8, kw, "or")) return true;
                    }
                    if (i + 4 < s.len and s[i + 4] == ' ') {
                        const kw = s[i + 1..i + 4];
                        if (std.mem.eql(u8, kw, "and")) return true;
                    }
                }
            }
        }
    }
    return false;
}

// Resolve an ID's name through CopyObject/Load chains to find the underlying variable.
// This helps inline stale `let` bindings that captured a `var` value once.
fn resolveSourceName(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), id: u32, depth: u32) ?[]const u8 {
    if (depth > 5) return names.get(id);
    const def = getDef(module, id) orelse return names.get(id);
    switch (def.op) {
        .Load, .CopyObject => {
            if (def.words.len < 4) return names.get(id);
            // Try to resolve further through the chain
            const deeper = resolveSourceName(module, names, def.words[3], depth + 1);
            // Only use the deeper name if it's different from the current name
            const current = names.get(id) orelse return deeper;
            if (deeper) |dn| {
                if (!std.mem.eql(u8, current, dn)) return dn;
            }
            return current;
        },
        else => return names.get(id),
    }
}

// Try to inline a condition expression for loop exit checks.
// Traces through Load/CopyObject to find the comparison and inlines it.
// Returns the inlined expression, or null if inlining isn't possible.
// Recursively mark condition IDs as dead (for compound conditions like LogicalAnd/Or)
fn markDeadConditions(module: *const ParsedModule, cond_id: u32, dead: *std.AutoHashMap(u32, void), depth: u32) void {
    if (depth > 5) return;
    dead.put(cond_id, {}) catch {};
    const cond_def = getDef(module, cond_id) orelse return;
    switch (cond_def.op) {
        .LogicalAnd, .LogicalOr => {
            if (cond_def.words.len >= 5) {
                markDeadConditions(module, cond_def.words[3], dead, depth + 1);
                markDeadConditions(module, cond_def.words[4], dead, depth + 1);
            }
        },
        .LogicalNot => {
            if (cond_def.words.len >= 4) {
                markDeadConditions(module, cond_def.words[3], dead, depth + 1);
            }
        },
        else => {},
    }
}

fn inlineConditionExpr(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), cond_id: u32, arena: std.mem.Allocator, depth: u32) ?[]const u8 {
    if (depth > 3) return null; // prevent infinite recursion
    const cond_def = getDef(module, cond_id) orelse return null;
    switch (cond_def.op) {
        // Comparison ops — inline as "lhs op rhs"
        .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual,
        .FOrdEqual, .FOrdNotEqual, .SLessThan, .SGreaterThan, .SLessThanEqual,
        .SGreaterThanEqual, .ULessThan, .UGreaterThan, .ULessThanEqual,
        .UGreaterThanEqual, .IEqual, .INotEqual
        => {
            if (cond_def.words.len < 5) return null;
            // Resolve operands through CopyObject/Load chains to use live variable names
            const lhs = resolveSourceName(module, names, cond_def.words[3], 0) orelse return null;
            const rhs = resolveSourceName(module, names, cond_def.words[4], 0) orelse return null;
            const op_sym = getBinOpSymbol(cond_def.op) orelse return null;
            var buf = std.ArrayList(u8).initCapacity(arena, lhs.len + rhs.len + op_sym.len + 8) catch return null;
            buf.appendSlice(arena, lhs) catch return null;
            buf.appendSlice(arena, " ") catch return null;
            buf.appendSlice(arena, op_sym) catch return null;
            buf.appendSlice(arena, " ") catch return null;
            buf.appendSlice(arena, rhs) catch return null;
            return buf.items;
        },
        // LogicalNot — inline as "!(expr)"
        .LogicalNot => {
            if (cond_def.words.len < 4) return null;
            const inner = inlineConditionExpr(module, names, cond_def.words[3], arena, depth + 1) orelse return null;
            var buf = std.ArrayList(u8).initCapacity(arena, inner.len + 4) catch return null;
            buf.appendSlice(arena, "!(") catch return null;
            buf.appendSlice(arena, inner) catch return null;
            buf.append(arena, ')') catch return null;
            return buf.items;
        },
        // LogicalAnd / LogicalOr — inline as "lhs && rhs" / "lhs || rhs"
        .LogicalAnd, .LogicalOr => {
            if (cond_def.words.len < 5) return null;
            const lhs = inlineConditionExpr(module, names, cond_def.words[3], arena, depth + 1);
            const rhs = inlineConditionExpr(module, names, cond_def.words[4], arena, depth + 1);
            if (lhs == null or rhs == null) return null;
            const join = if (cond_def.op == .LogicalAnd) " && " else " || ";
            var buf = std.ArrayList(u8).initCapacity(arena, lhs.?.len + rhs.?.len + 6) catch return null;
            buf.appendSlice(arena, lhs.?) catch return null;
            buf.appendSlice(arena, join) catch return null;
            buf.appendSlice(arena, rhs.?) catch return null;
            return buf.items;
        },
        // Load / CopyObject — trace through to the underlying value
        .Load, .CopyObject => {
            if (cond_def.words.len < 4) return null;
            return inlineConditionExpr(module, names, cond_def.words[3], arena, depth + 1);
        },
        else => return null,
    }
}

// Emit a single instruction — used for replaying deferred loop header instructions
fn emitSimpleInstruction(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, indent: u32) !void {
    switch (inst.op) {
        .Variable => {
            if (inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Function or sc == .Private) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const vn = names.get(inst.words[2]) orelse "v";
                    try writeIndentStatic(w, indent); try w.print("var {s}: {s};\n", .{ vn, rt });
                }
            }
        },
        .Load => {
            const result_name = names.get(inst.words[2]) orelse "v";
            const ptr = names.get(inst.words[3]) orelse "var";
            // Skip inlined loads (result name == pointer name means load was inlined)
            if (!std.mem.eql(u8, result_name, ptr)) {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, ptr });
            }
        },
        .Store => {
            const ptr = names.get(inst.words[1]) orelse "var";
            const val = names.get(inst.words[2]) orelse "0";
            // Skip store to depth output (handled by FragmentOutput struct return)
            const ptr_name = names.get(inst.words[1]);
            if (ptr_name != null and std.mem.eql(u8, ptr_name.?, "gl_FragDepth")) return;
            try writeIndentStatic(w, indent); try w.print("{s} = {s};\n", .{ ptr, val });
        },
        .AccessChain => {
            // Rename result to composite.field expression
            if (inst.words.len > 3) {
                const result_id = inst.words[2];
                const base_id = inst.words[3];
                const expr = buildAccessExpr(module, names, base_id, inst.words[4..], alloc) catch return;
                if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
            }
        },
        .Bitcast => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "0";
            try writeIndentStatic(w, indent); try w.print("let {s}: {s} = bitcast<{s}>({s});\n", .{ result_name, rt, rt, val });
        },
        .ExtInst => {
            // Handle GLSL.std.450 extended instructions in switch replay
            if (inst.words.len > 4) {
                const instruction = inst.words[4];
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                // Shared name mapping (same source of truth as the main emit path —
                // previously this replay switch had drifted and was missing
                // ldexp/pack*/unpack*/findILsb/findSMsb etc.).
                const func_name = try glslStd450WgslName(instruction);
                var args = std.ArrayList(u8).initCapacity(arena, 128) catch return;
                defer args.deinit(arena);
                for (inst.words[5..], 0..) |arg_id, ai| {
                    if (ai > 0) try args.appendSlice(arena, ", ");
                    try args.appendSlice(arena, names.get(arg_id) orelse "0");
                }
                try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
            }
        },
        else => {
            // For all other instructions, try emitCall/emitBinOp patterns
            // Comparison ops
            const maybe_op = getBinOpSymbol(inst.op);
            if (maybe_op != null) {
                try emitBinOp(module, names, inline_exprs, inst, maybe_op.?, w, arena, indent);
                return;
            }
            // Unary conversion ops
            const maybe_conv = getConvFunc(inst.op);
            if (maybe_conv != null) {
                try emitCall(module, names, inst, maybe_conv.?, w, arena, indent);
                return;
            }
            // Generic: emit as function call using opcode name
            if (inst.words.len < 3) return; // safety: need at least type + result
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
            defer args.deinit(arena);
            for (inst.words[3..], 0..) |arg_id, ai| {
                if (ai > 0) try args.appendSlice(arena, ", ");
                try args.appendSlice(arena, names.get(arg_id) orelse "0");
            }
            try writeIndentStatic(w, indent); try w.print("var {s}: {s} = {s}({s});\n", .{ result_name, rt, @tagName(inst.op), args.items });
        },
    }
}

fn getBinOpSymbol(op: spirv.Op) ?[]const u8 {
    return switch (op) {
        .IAdd => "+",
        .ISub => "-",
        .IMul => "*",
        .SDiv, .UDiv => "/",
        .FAdd => "+",
        .FSub => "-",
        .FMul => "*",
        .FDiv => "/",
        .FMod, .SMod, .SRem, .FRem, .UMod => "%",
        .ShiftRightLogical => ">>",
        .ShiftLeftLogical => "<<",
        .BitwiseAnd => "&",
        .BitwiseOr => "|",
        .BitwiseXor => "^",
        .LogicalAnd => "&&",
        .LogicalOr => "||",
        .SLessThan => "<",
        .SGreaterThan => ">",
        .ULessThan => "<",
        .UGreaterThan => ">",
        // Integer <=/>= variants — previously missing, so they fell through to the
        // generic fallback which emitted the opcode tag name (e.g. "SLessThanEqual")
        // as a bare identifier → naga "no definition in scope" (37 corpus shaders).
        .SLessThanEqual, .ULessThanEqual => "<=",
        .SGreaterThanEqual, .UGreaterThanEqual => ">=",
        .FOrdLessThan => "<",
        .FOrdGreaterThan => ">",
        .FOrdLessThanEqual => "<=",
        .FOrdGreaterThanEqual => ">=",
        .FOrdEqual => "==",
        .FOrdNotEqual => "!=",
        .IEqual => "==",
        .INotEqual => "!=",
        .VectorTimesScalar, .MatrixTimesScalar => "*",
        else => null,
    };
}

fn getConvFunc(op: spirv.Op) ?[]const u8 {
    return switch (op) {
        .ConvertFToU => "u32",
        .ConvertFToS => "i32",
        .ConvertSToF => "f32",
        .ConvertUToF => "f32",
        .UConvert => switch (op) { else => null },
        .FConvert => "f32",
        .SConvert => "i32",
        .SNegate => "-",
        .FNegate => "-",
        .Not => "!",
        .Bitcast => "bitcast", // will be handled specially
        else => null,
    };
}

fn emitCall(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
    defer args.deinit(arena);
    for (inst.words[3..], 0..) |arg_id, ai| {
        if (ai > 0) try args.appendSlice(arena, ", ");
        try args.appendSlice(arena, names.get(arg_id) orelse "0");
    }
    try writeIndentStatic(w, indent); try w.print("var {s}: {s} = {s}({s});\n", .{ result_name, rt, func, args.items });
}

fn emitSubgroupArith(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    // words[3] = scope, words[4] = group_op (reduce/scan/etc), words[5] = value
    const val = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
    // Map group_op to WGSL function
    // 0=Reduce, 1=InclusiveScan, 2=ExclusiveScan, 3=ClusteredReduce
    const group_op: u32 = if (inst.words.len > 4) inst.words[4] else 0;
    if (group_op == 0) {
        try writeIndentStatic(w, indent); try w.print("var {s}: {s} = subgroup{s}({s});\n", .{ result_name, rt, op, val });
    } else if (group_op == 1) {
        try writeIndentStatic(w, indent); try w.print("var {s}: {s} = subgroupInclusive{s}({s});\n", .{ result_name, rt, op, val });
    } else if (group_op == 2) {
        try writeIndentStatic(w, indent); try w.print("var {s}: {s} = subgroupExclusive{s}({s});\n", .{ result_name, rt, op, val });
    } else {
        try writeIndentStatic(w, indent); try w.print("var {s}: {s} = subgroup{s}({s});\n", .{ result_name, rt, op, val });
    }
}

fn emitAtomicBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const ptr = names.get(inst.words[3]) orelse "ptr";
    const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
    try writeIndentStatic(w, indent); try w.print("var {s}: {s} = atomic{s}(&{s}, {s});\n", .{ result_name, rt, op, ptr, val });
}

// Get the WGSL function name for a GLSL.std.450 instruction opcode, for the
// inline-EXPRESSION resolver only. Distinct from glslStd450WgslName (the
// statement-emit single source of truth): this one returns `null` to DECLINE
// inlining (the caller then falls back to the statement path, which uses the
// shared helper). It intentionally omits struct-returning / multi-result ops
// (modf 35/36, frexp 51/52, ldexp 53, findILsb/MSB 73/74) so they are emitted
// as statements rather than inlined incorrectly as a single expression.
fn getExtInstName(instruction: u32) ?[]const u8 {
    return switch (instruction) {
        1 => "round",
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
        25 => "atan2",
        26 => "pow",
        27 => "exp",
        28 => "log",
        29 => "exp2",
        30 => "log2",
        31 => "sqrt",
        32 => "inverseSqrt",
        37, 38, 39 => "min",
        40, 41, 42 => "max",
        43, 44, 45 => "clamp",
        46 => "mix",
        48 => "step",
        49 => "smoothstep",
        50 => "fma",
        // Packing (GLSL.std.450 54-58) → WGSL pack2x16* / pack4x8*
        54 => "pack4x8snorm",
        55 => "pack4x8unorm",
        56 => "pack2x16snorm",
        57 => "pack2x16unorm",
        58 => "pack2x16float",
        // Unpacking (GLSL.std.450 60-64)
        60 => "unpack2x16snorm",
        61 => "unpack2x16unorm",
        62 => "unpack2x16float",
        63 => "unpack4x8snorm",
        64 => "unpack4x8unorm",
        66 => "length",
        67 => "distance",
        68 => "cross",
        69 => "normalize",
        70 => "faceForward",
        71 => "reflect",
        72 => "refract",
        else => null,
    };
}

// Check if an opcode is an inlineable arithmetic op
fn isInlineableArithOp(op: spirv.Op) bool {
    return switch (op) {
        .FMul, .FAdd, .FSub, .FDiv, .FMod, .FNegate,
        .IMul, .IAdd, .ISub, .SDiv, .UDiv, .SMod,
        .VectorTimesScalar, .MatrixTimesScalar,
        .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual,
        .FOrdEqual, .FOrdNotEqual,
        .ExtInst
        => true,
        else => false,
    };
}

// Get the binary operator symbol for an opcode (for inline expression building)
fn getInlineBinOp(op: spirv.Op) ?[]const u8 {
    return switch (op) {
        .FMul, .IMul, .VectorTimesScalar, .MatrixTimesScalar => "*",
        .FAdd, .IAdd => "+",
        .FSub, .ISub => "-",
        .FDiv, .SDiv, .UDiv => "/",
        .FMod, .SMod => "%",
        .FOrdLessThan => "<",
        .FOrdGreaterThan => ">",
        .FOrdLessThanEqual => "<=",
        .FOrdGreaterThanEqual => ">=",
        .FOrdEqual => "==",
        .FOrdNotEqual => "!=",
        else => null,
    };
}

// Build an inline expression for an instruction result.
// Returns null if the instruction can't be inlined.
// Recursively inlines single-use operands.
fn buildInlineExpr(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), result_id: u32, arena: std.mem.Allocator, depth: u32) ?[]const u8 {
    if (depth > 4) return null; // limit nesting depth
    const inst = getDef(module, result_id) orelse return null;
    if (inst.words.len < 3) return null;

    switch (inst.op) {
        // Unary ops: -expr
        .FNegate, .SNegate => {
            if (inst.words.len < 4) return null;
            const inner = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, depth + 1);
            var buf = std.ArrayList(u8).initCapacity(arena, inner.len + 4) catch return null;
            buf.appendSlice(arena, "-") catch return null;
            // Wrap in parens if the inner expression contains an operator
            if (needsParens(inner)) {
                buf.appendSlice(arena, "(") catch return null;
                buf.appendSlice(arena, inner) catch return null;
                buf.appendSlice(arena, ")") catch return null;
            } else {
                buf.appendSlice(arena, inner) catch return null;
            }
            return buf.items;
        },
        // Binary arithmetic ops: lhs op rhs
        .FMul, .FAdd, .FSub, .FDiv, .FMod,
        .IMul, .IAdd, .ISub, .SDiv, .UDiv, .SMod,
        .VectorTimesScalar, .MatrixTimesScalar,
        .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual,
        .FOrdEqual, .FOrdNotEqual
        => {
            if (inst.words.len < 5) return null;
            const op_sym = getInlineBinOp(inst.op) orelse return null;
            const lhs = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, depth + 1);
            const rhs = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, depth + 1);
            var buf = std.ArrayList(u8).initCapacity(arena, lhs.len + rhs.len + op_sym.len + 8) catch return null;
            // Wrap lhs in parens if it contains a lower-precedence operator
            if (needsParensForOp(lhs, inst.op, true)) {
                buf.appendSlice(arena, "(") catch return null;
                buf.appendSlice(arena, lhs) catch return null;
                buf.appendSlice(arena, ")") catch return null;
            } else {
                buf.appendSlice(arena, lhs) catch return null;
            }
            buf.appendSlice(arena, " ") catch return null;
            buf.appendSlice(arena, op_sym) catch return null;
            buf.appendSlice(arena, " ") catch return null;
            // Wrap rhs in parens if needed
            if (needsParensForOp(rhs, inst.op, false)) {
                buf.appendSlice(arena, "(") catch return null;
                buf.appendSlice(arena, rhs) catch return null;
                buf.appendSlice(arena, ")") catch return null;
            } else {
                buf.appendSlice(arena, rhs) catch return null;
            }
            return buf.items;
        },
        // ExtInst (GLSL.std.450 function calls): func(arg1, arg2, ...)
        .ExtInst => {
            if (inst.words.len < 5) return null;
            const instruction = inst.words[4];
            const func_name = getExtInstName(instruction) orelse return null;
            // Don't inline functions with side effects or complex returns
            // Skip ModfStruct(35), FrexpStruct(51), determinant(33), matrixInverse(34)
            if (instruction == 33 or instruction == 34 or instruction == 35 or instruction == 51) return null;
            // Build function call with resolved operand expressions
            var buf = std.ArrayList(u8).initCapacity(arena, 64) catch return null;
            buf.appendSlice(arena, func_name) catch return null;
            buf.appendSlice(arena, "(") catch return null;
            if (inst.words.len > 5) {
                for (inst.words[5..], 0..) |arg_id, ai| {
                    if (ai > 0) buf.appendSlice(arena, ", ") catch return null;
                    const arg_expr = resolveOperandExpr(module, names, inline_exprs, arg_id, arena, depth + 1);
                    buf.appendSlice(arena, arg_expr) catch return null;
                }
            }
            buf.appendSlice(arena, ")") catch return null;
            return buf.items;
        },
        else => return null,
    }
}

// Resolve an operand's expression: check inline_exprs first, then try to build inline,
// finally fall back to the name.
fn resolveOperandExpr(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), id: u32, _arena: std.mem.Allocator, _depth: u32) []const u8 {
    _ = module;
    _ = _arena;
    _ = _depth;
    // Only use pre-built inline expressions (from the pre-scan)
    if (inline_exprs.get(id)) |expr| return expr;
    return names.get(id) orelse "v";
}

// Check if an expression contains operators and needs parentheses
fn needsParens(expr: []const u8) bool {
    // Contains any binary operator (but not inside function calls or swizzles)
    var depth: usize = 0;
    for (expr) |c| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0) {
            if (c == '+' or c == '-' or c == '*' or c == '/' or c == '%') return true;
        }
    }
    return false;
}

// Check if a sub-expression needs parens when used as operand of `op`
fn needsParensForOp(sub_expr: []const u8, parent_op: spirv.Op, is_lhs: bool) bool {
    _ = parent_op;
    _ = is_lhs;
    // Quick check: no spaces means it's a simple name/number, no parens needed
    var has_op = false;
    var depth: usize = 0;
    for (sub_expr) |c| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0) {
            if (c == ' ' and !has_op) {
                // A space could be part of "lhs + rhs"
                // But not part of "sin(x)" or "vec3f(1.0)"
                has_op = true;
            }
        }
    }
    if (!has_op) return false;

    // The sub-expression has spaces (likely an operator).
    // Conservative: wrap all compound expressions in parens when inside another op
    return true;
}

