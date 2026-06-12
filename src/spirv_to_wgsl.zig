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

/// Emit-once tracking for the generated `spvInverseN` matrix-inverse helpers.
/// WGSL has no `inverse` builtin (naga: "no definition in scope"), so GLSL
/// inverse() (GLSL.std.450 MatrixInverse=34) is lowered to a generated cofactor/
/// determinant helper. Each helper is emitted into the module preamble at most
/// once; these flags are set during the pre-emit scan and consumed when the
/// preamble is written. (Mirrors the spirit of the MSL backend injecting its
/// spvUnsafeArray template once.) Reset at `spirvToWGSL` entry.
threadlocal var needs_inverse_2: bool = false;
threadlocal var needs_inverse_3: bool = false;
threadlocal var needs_inverse_4: bool = false;

/// Square dimension (2/3/4) of the matrix operand of a MatrixInverse ExtInst, or
/// null if the operand is not a square float matrix of a supported size. Used by
/// both the pre-emit helper-detection scan and the ExtInst arms so the chosen
/// helper name (spvInverse2/3/4) and the emitted helper agree.
fn inverseMatrixDim(module: *const ParsedModule, result_type_id: u32) ?u32 {
    const ti = getDef(module, result_type_id) orelse return null;
    if (ti.op != .TypeMatrix or ti.words.len < 4) return null;
    const cols = ti.words[3];
    const col_inst = getDef(module, ti.words[2]) orelse return null;
    if (col_inst.op != .TypeVector or col_inst.words.len < 4) return null;
    const rows = col_inst.words[3];
    if (cols != rows) return null; // non-square has no inverse
    return switch (cols) {
        2, 3, 4 => cols,
        else => null,
    };
}

/// Write the generated WGSL inverse helper(s) flagged by the pre-emit scan into
/// the module preamble. Each is a closed-form cofactor/determinant inverse and is
/// naga-validated. Called once, before any function body, so the helper is in
/// scope at every call site.
fn writeInverseHelpers(w: anytype) !void {
    if (needs_inverse_2) {
        try w.writeAll(
            \\fn spvInverse2(m: mat2x2<f32>) -> mat2x2<f32> {
            \\    let det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
            \\    return mat2x2<f32>(m[1][1], -m[0][1], -m[1][0], m[0][0]) * (1.0 / det);
            \\}
            \\
            \\
        );
    }
    if (needs_inverse_3) {
        try w.writeAll(
            \\fn spvInverse3(m: mat3x3<f32>) -> mat3x3<f32> {
            \\    // Row-major element naming of the column-major matrix:
            \\    //   | a b c |
            \\    //   | d e f |
            \\    //   | g h i |
            \\    let a = m[0][0]; let b = m[1][0]; let c = m[2][0];
            \\    let d = m[0][1]; let e = m[1][1]; let f = m[2][1];
            \\    let g = m[0][2]; let h = m[1][2]; let i = m[2][2];
            \\    let A = (e * i - f * h);
            \\    let B = (f * g - d * i);
            \\    let C = (d * h - e * g);
            \\    let det = a * A + b * B + c * C;
            \\    let inv_det = 1.0 / det;
            \\    // mat3x3(col0, col1, col2); each value is inv[row][col].
            \\    return mat3x3<f32>(
            \\        A * inv_det,             // inv[0][0]
            \\        B * inv_det,             // inv[1][0]
            \\        C * inv_det,             // inv[2][0]
            \\        (c * h - b * i) * inv_det, // inv[0][1]
            \\        (a * i - c * g) * inv_det, // inv[1][1]
            \\        (b * g - a * h) * inv_det, // inv[2][1]
            \\        (b * f - c * e) * inv_det, // inv[0][2]
            \\        (c * d - a * f) * inv_det, // inv[1][2]
            \\        (a * e - b * d) * inv_det, // inv[2][2]
            \\    );
            \\}
            \\
            \\
        );
    }
    if (needs_inverse_4) {
        try w.writeAll(
            \\fn spvInverse4(m: mat4x4<f32>) -> mat4x4<f32> {
            \\    let a00 = m[0][0]; let a01 = m[0][1]; let a02 = m[0][2]; let a03 = m[0][3];
            \\    let a10 = m[1][0]; let a11 = m[1][1]; let a12 = m[1][2]; let a13 = m[1][3];
            \\    let a20 = m[2][0]; let a21 = m[2][1]; let a22 = m[2][2]; let a23 = m[2][3];
            \\    let a30 = m[3][0]; let a31 = m[3][1]; let a32 = m[3][2]; let a33 = m[3][3];
            \\    let b00 = a00 * a11 - a01 * a10;
            \\    let b01 = a00 * a12 - a02 * a10;
            \\    let b02 = a00 * a13 - a03 * a10;
            \\    let b03 = a01 * a12 - a02 * a11;
            \\    let b04 = a01 * a13 - a03 * a11;
            \\    let b05 = a02 * a13 - a03 * a12;
            \\    let b06 = a20 * a31 - a21 * a30;
            \\    let b07 = a20 * a32 - a22 * a30;
            \\    let b08 = a20 * a33 - a23 * a30;
            \\    let b09 = a21 * a32 - a22 * a31;
            \\    let b10 = a21 * a33 - a23 * a31;
            \\    let b11 = a22 * a33 - a23 * a32;
            \\    let det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
            \\    let inv_det = 1.0 / det;
            \\    return mat4x4<f32>(
            \\        ( a11 * b11 - a12 * b10 + a13 * b09) * inv_det,
            \\        (-a01 * b11 + a02 * b10 - a03 * b09) * inv_det,
            \\        ( a31 * b05 - a32 * b04 + a33 * b03) * inv_det,
            \\        (-a21 * b05 + a22 * b04 - a23 * b03) * inv_det,
            \\        (-a10 * b11 + a12 * b08 - a13 * b07) * inv_det,
            \\        ( a00 * b11 - a02 * b08 + a03 * b07) * inv_det,
            \\        (-a30 * b05 + a32 * b02 - a33 * b01) * inv_det,
            \\        ( a20 * b05 - a22 * b02 + a23 * b01) * inv_det,
            \\        ( a10 * b10 - a11 * b08 + a13 * b06) * inv_det,
            \\        (-a00 * b10 + a01 * b08 - a03 * b06) * inv_det,
            \\        ( a30 * b04 - a31 * b02 + a33 * b00) * inv_det,
            \\        (-a20 * b04 + a21 * b02 - a23 * b00) * inv_det,
            \\        (-a10 * b09 + a11 * b07 - a12 * b06) * inv_det,
            \\        ( a00 * b09 - a01 * b07 + a02 * b06) * inv_det,
            \\        (-a30 * b03 + a31 * b01 - a32 * b00) * inv_det,
            \\        ( a20 * b03 - a21 * b01 + a22 * b00) * inv_det,
            \\    );
            \\}
            \\
            \\
        );
    }
}

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

/// Safe display name for an `Op` in a diagnostic. `Op` is a NON-EXHAUSTIVE enum
/// (`_,`), so a SPIR-V opcode glslpp does not name (e.g. OpIAddCarry=149 from
/// GLSL `uaddCarry`) parses to a tag-less value. `@tagName` PANICS on such a
/// value ("invalid enum value"), which turned the honest-error path into a hard
/// process crash on perfectly valid input. Use this instead of `@tagName` at any
/// honest-error site that an UNKNOWN op can reach (the main + replay fallbacks).
fn opName(op: spirv.Op) []const u8 {
    return std.enums.tagName(spirv.Op, op) orelse "unknown";
}

/// SPIR-V extended-arithmetic opcodes whose result is a 2-member struct. `spirv.Op`
/// is non-exhaustive and does NOT name these (`@tagName` would panic), so they must
/// be matched by raw opcode number, not an `.IAddCarry`-style enum literal.
/// OpIAddCarry = 149, OpISubBorrow = 150.
fn isAddCarry(op: spirv.Op) bool {
    return @intFromEnum(op) == 149;
}
fn isSubBorrow(op: spirv.Op) bool {
    return @intFromEnum(op) == 150;
}
fn isAddCarryOrSubBorrow(op: spirv.Op) bool {
    return isAddCarry(op) or isSubBorrow(op);
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

/// How a mid-body (early) `OpReturn` in the ENTRY function is lowered. WGSL's
/// entry point returns the output struct/value, so a void SPIR-V return cannot
/// simply become `return;` — it must reassemble the current outputs.
///   * `.none`    — non-entry (helper) function; legacy behaviour (a void return
///                  with no inout result is dropped; see the `.Return` arm).
///   * `.stmt`    — the outputs accumulate in a single named local that the
///                  trailing return references verbatim (`vertex_out`, a color
///                  `var`, or a void entry's `return;`); emit this statement at
///                  the early-return point.
///   * `.honest_error` — the trailing return is ASSEMBLED from end-captured
///                  values (frag_depth/MRT struct, or the single-store direct
///                  return), which an early return cannot reproduce at the right
///                  program point; fail loud rather than silently miscompile.
const EarlyReturnMode = union(enum) {
    none,
    stmt: []const u8,
    honest_error,
};

/// Record the detail for a mid-body early return that cannot be cleanly
/// structurized into WGSL, then return the honest error.
fn recordUnsupportedEarlyReturn() error{UnsupportedEarlyReturn} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "mid-body early 'return' targets an assembled entry output (frag_depth/MRT/direct-return) that WGSL structurization cannot express",
        .{},
    ) catch null;
    return error.UnsupportedEarlyReturn;
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
        // 34 (MatrixInverse / GLSL inverse()) intentionally UNMAPPED: WGSL has no
        // matrix-inverse builtin. Emitting `matrixInverse(m)` is silent-wrong
        // (naga: "no definition in scope"). Fall through to recordUnsupportedExtInst
        // for an honest error until an inline WGSL inverse helper is emitted.
        35 => "modf", // ModfStruct
        36 => "modf",
        37 => "min", // FMin
        38 => "min", // UMin
        39 => "min", // SMin
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
        // Bit-scan ops. WGSL spells these firstTrailingBit/firstLeadingBit. They
        // are emitted here under their final WGSL names directly so BOTH ExtInst
        // paths (main + replay) get the right builtin — the old main-path-only
        // special-case remap from "findILsb"/"findSMsb"/"findUMsb" is retired.
        //   FindILsb  (73) → firstTrailingBit
        //   FindSMsb  (74) → firstLeadingBit (signed MSB)
        //   FindUMsb  (75) → firstLeadingBit (unsigned MSB)
        73 => "firstTrailingBit",
        74 => "firstLeadingBit",
        75 => "firstLeadingBit",
        // NMin/NMax/NClamp (79/80/81) are the NaN-min/max/clamp variants. WGSL's
        // min/max/clamp already propagate the non-NaN operand (matching the N*
        // semantics), so map them to the plain builtins (spirv-cross does the
        // same). naga-validated.
        79 => "min",
        80 => "max",
        81 => "clamp",
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

/// Map a SPIR-V `ImageFormat` operand (OpTypeImage word 8) to the WGSL storage
/// texel-format keyword, or null if WGSL cannot represent it. Only the formats
/// valid in `texture_storage_*` per the WGSL spec are listed; anything else
/// (Unknown, or a format with no WGSL storage equivalent like Rg16f/R8/Rgb10A2)
/// returns null so the caller can fail loud or fall back, never silently emit
/// the wrong format. (SPIR-V ImageFormat enumerants, from the spec.)
fn spirvImageFormatToWgsl(fmt: u32) ?[]const u8 {
    return switch (fmt) {
        1 => "rgba32float", // Rgba32f
        2 => "rgba16float", // Rgba16f
        3 => "r32float", // R32f
        4 => "rgba8unorm", // Rgba8
        5 => "rgba8snorm", // Rgba8Snorm
        6 => "rg32float", // Rg32f
        21 => "rgba32sint", // Rgba32i
        22 => "rgba16sint", // Rgba16i
        23 => "rgba8sint", // Rgba8i
        24 => "r32sint", // R32i
        25 => "rg32sint", // Rg32i
        30 => "rgba32uint", // Rgba32ui
        31 => "rgba16uint", // Rgba16ui
        32 => "rgba8uint", // Rgba8ui
        33 => "r32uint", // R32ui
        35 => "rg32uint", // Rg32ui
        else => null, // Unknown(0) or a non-WGSL-storage format
    };
}

/// Resolve a stage-input variable to the struct type id of its GLSL interface
/// block (`in Block { … } inst;`), or null if it is a built-in or its
/// (one-TypePointer-unwrapped) pointee is not a TypeStruct. A struct-typed stage
/// input is ALWAYS an interface block here — plain non-block stage I/O is
/// scalar/vector. Single source of truth shared by the redefinition pre-seed and
/// the IO-block emit path near `fn main`, so the two never drift (a divergence
/// would silently drop or duplicate the struct).
fn ioBlockStructType(module: *const ParsedModule, type_id: u32, builtin: ?spirv.BuiltIn) ?u32 {
    if (builtin != null) return null;
    var sty = type_id;
    if (getDef(module, type_id)) |pi| {
        if (pi.op == .TypePointer and pi.words.len > 3) sty = pi.words[3];
    }
    const sdef = getDef(module, sty) orelse return null;
    if (sdef.op != .TypeStruct) return null;
    return sty;
}

/// True if `target` is reachable from `root_type_id` by descending through
/// pointer / array / matrix / vector wrappers and struct members. Used to detect
/// a struct that is BOTH a stage-input interface block AND a data (UBO/SSBO)
/// member — see the redefinition pre-seed. Depth-capped against malformed cycles.
fn typeReachesStruct(module: *const ParsedModule, root_type_id: u32, target: u32, depth: u32) bool {
    if (depth > 16) return false;
    if (root_type_id == target) return true;
    const inst = getDef(module, root_type_id) orelse return false;
    switch (inst.op) {
        .TypePointer => if (inst.words.len > 3) return typeReachesStruct(module, inst.words[3], target, depth + 1),
        .TypeArray, .TypeRuntimeArray, .TypeMatrix, .TypeVector => if (inst.words.len > 2)
            return typeReachesStruct(module, inst.words[2], target, depth + 1),
        .TypeStruct => for (inst.words[2..]) |mt| {
            if (typeReachesStruct(module, mt, target, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// True if `type_id` is (or transitively contains) an OpTypeArray whose length
/// operand is a specialization constant (OpSpecConstant / OpSpecConstantOp). WGSL
/// allows an `override`-sized array ONLY as a `var<workgroup>` type — a spec-
/// constant-sized function-local, struct-member, or storage array is therefore
/// unrepresentable. Used to fail loud instead of emitting a runtime `array<T>`
/// (naga-invalid as a local) or dropping members to an empty struct (#170 I).
fn typeContainsSpecConstArray(module: *const ParsedModule, type_id: u32, depth: u32) bool {
    if (depth > 16) return false;
    const inst = getDef(module, type_id) orelse return false;
    switch (inst.op) {
        .TypeArray => {
            if (inst.words.len > 3) {
                if (getDef(module, inst.words[3])) |len| {
                    if (len.op == .SpecConstant or len.op == .SpecConstantOp) return true;
                }
            }
            if (inst.words.len > 2) return typeContainsSpecConstArray(module, inst.words[2], depth + 1);
        },
        .TypeRuntimeArray, .TypePointer => {
            const elem_idx: usize = if (inst.op == .TypePointer) 3 else 2;
            if (inst.words.len > elem_idx) return typeContainsSpecConstArray(module, inst.words[elem_idx], depth + 1);
        },
        .TypeStruct => for (inst.words[2..]) |mt| {
            if (typeContainsSpecConstArray(module, mt, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}

/// GLSL allows scalar overloads of the geometric builtins (`normalize(float)`,
/// `length(float)`, …) but WGSL defines `normalize`/`length`/`distance`/
/// `reflect` only on vectors — naga rejects the scalar call ("wrong type passed
/// as argument #1"). Return the value-equivalent WGSL scalar expression, or null
/// if this is not a scalar geometric op (use the normal `func(args)` path).
///   length(x)      -> abs(x)
///   distance(a,b)  -> abs(a - b)
///   normalize(x)   -> sign(x)        (x/|x| for a scalar)
///   reflect(I,N)   -> I - 2*(N*I)*N
/// Scalar `refract` is deliberately NOT lowered here — its formula is value-
/// sensitive and naga only type-checks, so a hand-rolled version could pass naga
/// while computing the wrong result (a silent-wrong). The caller honest-errors it.
fn scalarGeomLower(arena: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), instruction: u32, result_type_id: u32, arg_ids: []const u32) ?[]const u8 {
    // length(66)/distance(67) always return a scalar, so probe the ARGUMENT type;
    // normalize(69)/reflect(71) return the argument type, so the result suffices.
    const probe_type: u32 = switch (instruction) {
        66, 67 => if (arg_ids.len >= 1) (resolveTypeOf(module, arg_ids[0]) orelse return null) else return null,
        69, 71 => result_type_id,
        else => return null,
    };
    const ti = getDef(module, probe_type) orelse return null;
    if (ti.op != .TypeFloat) return null; // vector form is valid WGSL — leave it.
    const a0 = if (arg_ids.len >= 1) (names.get(arg_ids[0]) orelse "0.0") else "0.0";
    return switch (instruction) {
        66 => std.fmt.allocPrint(arena, "abs({s})", .{a0}) catch null,
        67 => blk: {
            const a1 = if (arg_ids.len >= 2) (names.get(arg_ids[1]) orelse "0.0") else "0.0";
            break :blk std.fmt.allocPrint(arena, "abs(({s}) - ({s}))", .{ a0, a1 }) catch null;
        },
        69 => std.fmt.allocPrint(arena, "sign({s})", .{a0}) catch null,
        71 => blk: {
            const a1 = if (arg_ids.len >= 2) (names.get(arg_ids[1]) orelse "0.0") else "0.0";
            break :blk std.fmt.allocPrint(arena, "(({s}) - 2.0 * (({s}) * ({s})) * ({s}))", .{ a0, a1, a0, a1 }) catch null;
        },
        else => null,
    };
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

/// How a NON-depth coordinate must be reshaped for an arrayed sampled texture
/// (sampler2DArray / samplerCubeArray / sampler1DArray). This is the non-depth
/// analogue of `depthCompareShape`: WGSL's `texture_2d_array` / `texture_cube_array`
/// take the array layer as a SEPARATE integer argument right after the spatial
/// coordinate, while glslang packs it as a trailing coordinate component. So the
/// coordinate must be sliced to exactly the texture's spatial dimension and the
/// layer extracted into its own `i32(...)` argument, or naga rejects ("coordinate
/// type does not match dimension"). `arrayed == false` means leave the call alone.
const ArrayedSampleShape = struct {
    /// Spatial component count: 1 (1D), 2 (2D), 3 (cube). The layer is the
    /// component just past these (.x→.y, .xy→.z, .xyz→.w).
    comps: u32,
    /// True only for a non-depth arrayed sampled texture; false otherwise so the
    /// existing (non-array) emit path is used verbatim.
    arrayed: bool,
};

/// Derive the arrayed-sample reshape from the OpTypeImage behind a sampled-image
/// value id (the combined sampler operand of OpImageSample*). DEPTH images are
/// excluded here — those go through emitDepthCompare, which already does its own
/// layer split. Accepts the same pointer/sampled-image unwrap chain as
/// depthCompareShape.
fn arrayedSampleShape(module: *const ParsedModule, sampled_image_value_id: u32) ArrayedSampleShape {
    const none = ArrayedSampleShape{ .comps = 2, .arrayed = false };
    const type_id = getTypeOf(module, sampled_image_value_id) orelse return none;
    var inst = getDef(module, type_id) orelse return none;
    if (inst.op == .TypePointer and inst.words.len > 3) {
        inst = getDef(module, inst.words[3]) orelse return none;
    }
    if (inst.op == .TypeSampledImage and inst.words.len > 2) {
        inst = getDef(module, inst.words[2]) orelse return none;
    }
    if (inst.op != .TypeImage or inst.words.len <= 5) return none;
    // Depth textures take the depth-compare path; not our concern here.
    const is_depth = inst.words.len > 4 and inst.words[4] == 1;
    if (is_depth) return none;
    const arrayed = inst.words[5] == 1;
    if (!arrayed) return none;
    const comps: u32 = switch (inst.words[3]) {
        0 => 1, // 1D family → vec1 spatial (scalar .x)
        3 => 3, // Cube → vec3 direction
        else => 2, // 2D family → vec2 spatial
    };
    return .{ .comps = comps, .arrayed = true };
}

/// Shape of an image-size query (OpImageQuerySize[Lod]) on `image_value_id`:
/// whether the image is arrayed and how many components `textureDimensions`
/// returns (its spatial dims). GLSL `textureSize`/`imageSize` on an arrayed
/// sampler returns the spatial dims PLUS a trailing layer count, but WGSL
/// `textureDimensions` returns only the spatial dims — the layer count is a
/// separate `textureNumLayers` call. `arrayed` true means the caller must append
/// `textureNumLayers`. `spatial` is the textureDimensions component count
/// (1 for 1D, 2 for 2D/Cube, 3 for 3D). Accepts the pointer / sampled-image
/// unwrap chain used by the other image-shape helpers.
/// A vertex stage `out matNxM` flattened into N column @location members
/// (`{base}_0 … {base}_{cols-1}`, each `col_type`). WGSL forbids a matrix at a
/// single @location, so the struct emits the columns and the Store site splits a
/// whole-matrix write into per-column writes. Keyed by the output variable id.
const MatrixOutput = struct { base_name: []const u8, cols: u32, col_type: []const u8 };

const ImageQueryShape = struct { arrayed: bool, spatial: u32 };
fn imageQueryShape(module: *const ParsedModule, image_value_id: u32) ImageQueryShape {
    const fallback = ImageQueryShape{ .arrayed = false, .spatial = 2 };
    const type_id = getTypeOf(module, image_value_id) orelse return fallback;
    var inst = getDef(module, type_id) orelse return fallback;
    if (inst.op == .TypePointer and inst.words.len > 3) {
        inst = getDef(module, inst.words[3]) orelse return fallback;
    }
    if (inst.op == .TypeSampledImage and inst.words.len > 2) {
        inst = getDef(module, inst.words[2]) orelse return fallback;
    }
    if (inst.op != .TypeImage or inst.words.len <= 5) return fallback;
    const spatial: u32 = switch (inst.words[3]) {
        0 => 1, // 1D
        2 => 3, // 3D
        else => 2, // 2D / Cube
    };
    return .{ .arrayed = inst.words[5] == 1, .spatial = spatial };
}

/// The signed WGSL vector/scalar type alias for `n` integer components
/// (1→"i32", 2→"vec2i", 3→"vec3i"), used to convert an unsigned
/// `textureDimensions` result to the signed GLSL query type.
fn signedIntVecType(n: u32) []const u8 {
    return switch (n) {
        1 => "i32",
        3 => "vec3i",
        else => "vec2i",
    };
}

/// The spatial-coordinate swizzle (".x"/".xy"/".xyz") and the layer-component
/// swizzle (".y"/".z"/".w") for an `ArrayedSampleShape`. At the FLOAT-coord
/// sample sites (ImageSample{Implicit,Explicit}Lod, ImageGather) the layer is
/// `i32(round(coord.<layer>))` — rounded for glslang parity (floor(layer+0.5)).
/// At the INTEGER-coord ImageFetch (texelFetch) site the layer component is
/// already an integer, so it is `i32(coord.<layer>)` with NO round.
fn arrayedCoordSwizzle(comps: u32) []const u8 {
    return switch (comps) {
        1 => ".x",
        3 => ".xyz",
        else => ".xy",
    };
}

fn arrayedLayerSwizzle(comps: u32) []const u8 {
    return switch (comps) {
        1 => ".y",
        3 => ".w",
        else => ".z",
    };
}

/// Spatial dimensionality (1/2/3) of the sampler behind a sampled-image value,
/// for lowering GLSL projective sampling (textureProj*). WGSL has no projective
/// builtin, so textureProj is lowered to a manual perspective divide: the
/// coordinate is divided by its LAST component, then the leading `dim`
/// components are sampled with a plain textureSample/textureSampleLevel. The
/// number of leading components must match the texture dimension exactly (.x for
/// 1D, .xy for 2D, .xyz for 3D) or naga rejects ("coordinate type does not match
/// dimension"). Returns null for dims with no clean projective mapping (cube /
/// arrayed), which the caller honest-errors. SPIR-V Dim: 0=1D, 1=2D, 2=3D,
/// 3=Cube.
fn projectiveCoordDim(module: *const ParsedModule, sampled_image_value_id: u32) ?u32 {
    const type_id = getTypeOf(module, sampled_image_value_id) orelse return null;
    var inst = getDef(module, type_id) orelse return null;
    if (inst.op == .TypePointer and inst.words.len > 3) {
        inst = getDef(module, inst.words[3]) orelse return null;
    }
    if (inst.op == .TypeSampledImage and inst.words.len > 2) {
        inst = getDef(module, inst.words[2]) orelse return null;
    }
    if (inst.op != .TypeImage or inst.words.len <= 3) return null;
    // Arrayed projective forms have no clean WGSL mapping (the array layer is a
    // separate non-projective argument) — defer to the honest-error path.
    const arrayed = inst.words.len > 5 and inst.words[5] == 1;
    if (arrayed) return null;
    return switch (inst.words[3]) {
        0 => 1, // 1D
        1 => 2, // 2D
        2 => 3, // 3D
        else => null, // Cube (3) / SubpassData / Buffer: no clean projective map
    };
}

/// Component count of the vector type behind `value_id` (e.g. 4 for a vec4
/// coordinate), or null if it is not a vector. Used by projective sampling to
/// pick the divisor = the value's LAST component, which GLSL's textureProj
/// divides by regardless of the sampler dimension. TypeVector layout:
/// [op, result_id, component_type, count].
fn vectorComponentCount(module: *const ParsedModule, value_id: u32) ?u32 {
    const type_id = getTypeOf(module, value_id) orelse return null;
    const inst = getDef(module, type_id) orelse return null;
    if (inst.op != .TypeVector or inst.words.len <= 3) return null;
    return inst.words[3];
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

/// True iff `s` is a bare, untyped numeric literal: an optional leading `-`,
/// digits, at most one `.`, and NOTHING else (no type suffix, no identifier
/// chars, no parens). Used to gate scalar-constant `f`/`i` typing so it never
/// touches an OpName alias (an identifier), an already-typed literal (`1.0f`,
/// `7u`), or a composite-constructor string (contains `(`).
fn isPlainNumericLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') i = 1;
    if (i >= s.len) return false;
    var seen_digit = false;
    var seen_dot = false;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '0'...'9' => seen_digit = true,
            '.' => {
                if (seen_dot) return false;
                seen_dot = true;
            },
            else => return false, // letter (suffix/identifier), '(', etc.
        }
    }
    return seen_digit;
}

/// Marks a struct member as the target of WGSL atomic ops.
/// `scalar` → wrap whole field in `atomic<T>` (e.g. `counter: atomic<u32>`)
/// `array_element` → wrap element type (e.g. `data: array<atomic<u32>>`)
const AtomicFieldKind = enum { scalar, array_element };

const AtomicFieldKey = struct { struct_id: u32, member_idx: u32 };
const AtomicFieldMap = std.AutoHashMap(AtomicFieldKey, AtomicFieldKind);

// ---------------------------------------------------------------------------
// Pass 4 (#170 G5 / A2): sub-16 uniform array members → array<vec4> + swizzle.
//
// WGSL's uniform address space requires every array element stride to be a
// multiple of 16 bytes. A uniform block with a scalar-element (`float arr[N]`,
// stride 4) or vec2-element (`vec2 arr[N]`, stride 8) array member is rejected
// by naga: "array stride 4 is not a multiple of the required alignment 16".
// `@stride(16)` is NOT valid WGSL, so the only portable lowering is to widen
// the array element to a vec4 and swizzle it back on every access:
//   `float arr[N]` → `arr: array<vec4<f32>, N>`, access `U.arr[i].x`
//   `vec2  arr[N]` → `arr: array<vec4<f32>, N>`, access `U.arr[i].xy`
// vec3/vec4/matrix array members are already 16-aligned → NOT wrapped.
// Storage buffers (SSBO) tolerate stride 4/8, so this is UNIFORM-ONLY.
//
// `WrappedUniformMemberKind` records the swizzle to re-narrow the widened
// element. The map is keyed by (struct_type_id, member_idx), mirroring
// AtomicFieldMap, and is consulted at both struct-emission and access-site.
const WrappedUniformMemberKind = enum {
    x, // scalar element  → array<vec4<T>, N>, access `[i].x`
    xy, // vec2 element    → array<vec4<T>, N>, access `[i].xy`

    fn swizzle(self: WrappedUniformMemberKind) []const u8 {
        return switch (self) {
            .x => ".x",
            .xy => ".xy",
        };
    }
};
const WrappedUniformMemberKey = struct { struct_id: u32, member_idx: u32 };
const WrappedUniformMemberMap = std.AutoHashMap(WrappedUniformMemberKey, WrappedUniformMemberKind);

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

/// #170 (H): resolve the constant length of an `OpTypeArray` (0 if unresolved).
fn arrayTypeLen(module: *const ParsedModule, array_def: Instruction) u32 {
    if (array_def.op != .TypeArray or array_def.words.len < 4) return 0;
    const ld = getDef(module, array_def.words[3]) orelse return 0;
    return if (ld.op == .Constant and ld.words.len > 3) ld.words[3] else 0;
}

/// #170 (H): true if any member of this struct is an aggregate (struct/array/
/// matrix) — i.e. it cannot be a flat list of scalar/vector `@location` members
/// and the stage-IO block must be deep-flattened + reassembled (inputs:
/// emitFlattenedIoParams/buildIoReconExpr; outputs: collectOutputLeaves).
fn blockHasAggregateMember(module: *const ParsedModule, struct_id: u32) bool {
    const sdef = getDef(module, struct_id) orelse return false;
    if (sdef.op != .TypeStruct) return false;
    for (sdef.words[2..]) |mt_id| {
        const md = getDef(module, mt_id) orelse continue;
        switch (md.op) {
            .TypeStruct, .TypeArray, .TypeRuntimeArray, .TypeMatrix => return true,
            else => {},
        }
    }
    return false;
}

/// #170 (H): emit the flattened leaf `@location` entry parameters of a
/// nested stage-IO block. A struct member recurses with its name folded into
/// `prefix` (`VertexIn` → `VertexIn_a` → leaf `VertexIn_a_b`); an array member
/// expands per element (`a` → `a_0 … a_{N-1}`); a scalar/vector leaf emits one
/// param and bumps `*loc`. Each param is comma-separated; `*first` tracks whether
/// the leading separator is owed (the outer param loop already wrote the comma
/// before this block). A matrix member or an array of aggregates cannot be
/// expressed as scalar/vector `@location`s — fail loud.
fn emitFlattenedIoParams(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, prefix: []const u8, loc: *u32, is_fragment: bool, w: anytype, arena: std.mem.Allocator, first: *bool) !void {
    const sdef = getDef(module, struct_id) orelse return;
    for (sdef.words[2..], 0..) |mt_id, mi| {
        var mname_buf: [32]u8 = undefined;
        const mname = getMemberName(module, struct_id, @intCast(mi), &mname_buf);
        const child = try std.fmt.allocPrint(arena, "{s}_{s}", .{ prefix, mname });
        const md = getDef(module, mt_id) orelse continue;
        switch (md.op) {
            .TypeStruct => try emitFlattenedIoParams(module, names, mt_id, child, loc, is_fragment, w, arena, first),
            .TypeArray => {
                const elem = md.words[2];
                const ed = getDef(module, elem);
                if (ed != null and (ed.?.op == .TypeArray or ed.?.op == .TypeRuntimeArray or ed.?.op == .TypeMatrix)) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL stage-IO flattening does not support an array of arrays/matrices at a @location", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const len = arrayTypeLen(module, md);
                const elem_is_struct = ed != null and ed.?.op == .TypeStruct;
                const etype = if (!elem_is_struct) try wgslType(module, elem, names, arena) else "";
                var k: u32 = 0;
                while (k < len) : (k += 1) {
                    const ef = try std.fmt.allocPrint(arena, "{s}_{d}", .{ child, k });
                    if (elem_is_struct) {
                        try emitFlattenedIoParams(module, names, elem, ef, loc, is_fragment, w, arena, first);
                    } else {
                        try emitOneIoParam(ef, etype, is_fragment and isIntegerWgslType(etype), loc, w, first);
                    }
                }
            },
            .TypeMatrix, .TypeRuntimeArray => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL stage-IO flattening does not support a matrix/runtime-array member at a @location", .{}) catch null;
                return error.UnsupportedOp;
            },
            else => {
                const mtype = try wgslType(module, mt_id, names, arena);
                const flat = memberHasFlat(module, struct_id, @intCast(mi)) or isIntegerWgslType(mtype);
                try emitOneIoParam(child, mtype, is_fragment and flat, loc, w, first);
            },
        }
    }
}

/// Emit one flattened leaf @location param (comma-managed via `*first`).
/// Fragment integer/flat varyings need @interpolate(flat); vertex inputs are
/// attributes (never interpolated) so the attribute would be illegal there.
fn emitOneIoParam(name: []const u8, type_name: []const u8, want_flat: bool, loc: *u32, w: anytype, first: *bool) !void {
    const interp: []const u8 = if (want_flat) "@interpolate(flat) " else "";
    if (!first.*) try w.writeAll(", ");
    first.* = false;
    try w.print("@location({d}) {s}{s}: {s}", .{ loc.*, interp, name, type_name });
    loc.* += 1;
}

/// #170 (H): build the constructor expression that reassembles a nested stage-IO
/// block value from its flattened leaf params — `VertexIn(Foo(VertexIn_a_a,
/// VertexIn_a_b), …)`, `Blk(array<f32, 4>(b_a_0, b_a_1, b_a_2, b_a_3))`. The
/// leaf-name folding mirrors emitFlattenedIoParams exactly so names line up.
fn buildIoReconExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, prefix: []const u8, buf: *std.ArrayList(u8), arena: std.mem.Allocator) !void {
    const sdef = getDef(module, struct_id) orelse return;
    const tname = names.get(struct_id) orelse "Block";
    try buf.print(arena, "{s}(", .{tname});
    for (sdef.words[2..], 0..) |mt_id, mi| {
        if (mi > 0) try buf.appendSlice(arena, ", ");
        var mname_buf: [32]u8 = undefined;
        const mname = getMemberName(module, struct_id, @intCast(mi), &mname_buf);
        const child = try std.fmt.allocPrint(arena, "{s}_{s}", .{ prefix, mname });
        const md = getDef(module, mt_id) orelse continue;
        if (md.op == .TypeStruct) {
            try buildIoReconExpr(module, names, mt_id, child, buf, arena);
        } else if (md.op == .TypeArray) {
            const elem = md.words[2];
            const ed = getDef(module, elem);
            const len = arrayTypeLen(module, md);
            const etype = try wgslType(module, mt_id, names, arena); // "array<T, N>"
            try buf.print(arena, "{s}(", .{etype});
            var k: u32 = 0;
            while (k < len) : (k += 1) {
                if (k > 0) try buf.appendSlice(arena, ", ");
                const ef = try std.fmt.allocPrint(arena, "{s}_{d}", .{ child, k });
                if (ed != null and ed.?.op == .TypeStruct) {
                    try buildIoReconExpr(module, names, elem, ef, buf, arena);
                } else {
                    try buf.appendSlice(arena, ef);
                }
            }
            try buf.appendSlice(arena, ")");
        } else {
            try buf.appendSlice(arena, child);
        }
    }
    try buf.appendSlice(arena, ")");
}

/// #170 (H): a leaf of a flattened vertex OUTPUT interface block — a
/// scalar/vector that becomes one `@location` member of VertexOutput, copied out
/// of the reassembled local at return. `flat_name` is the folded member name
/// (`a_0`), `src` the access path into the local (`io_foo.a[0]`).
const OutputLeaf = struct { flat_name: []const u8, type_name: []const u8, is_int: bool, src: []const u8 };

/// #170 (H): recursively collect the scalar/vector leaves of a vertex OUTPUT
/// interface block, folding member names into `flat_prefix` (`a` → `a_0` per array
/// element) and access paths into `src_path` (`io_foo` → `io_foo.a[0]`). A
/// struct member recurses; a scalar/vector-element array expands per element; a
/// matrix member or an array of aggregates is the unrepresentable case and fails
/// loud (rather than emit a struct/array/matrix at a `@location` that naga rejects).
fn collectOutputLeaves(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, flat_prefix: []const u8, src_path: []const u8, leaves: *std.ArrayList(OutputLeaf), arena: std.mem.Allocator) !void {
    const sdef = getDef(module, struct_id) orelse return;
    for (sdef.words[2..], 0..) |mt_id, mi| {
        var mb: [32]u8 = undefined;
        const mname = getMemberName(module, struct_id, @intCast(mi), &mb);
        const child_flat = if (flat_prefix.len == 0)
            try arena.dupe(u8, mname)
        else
            try std.fmt.allocPrint(arena, "{s}_{s}", .{ flat_prefix, mname });
        const child_src = try std.fmt.allocPrint(arena, "{s}.{s}", .{ src_path, mname });
        const md = getDef(module, mt_id) orelse continue;
        switch (md.op) {
            .TypeStruct => try collectOutputLeaves(module, names, mt_id, child_flat, child_src, leaves, arena),
            .TypeArray => {
                const elem = md.words[2];
                const ed = getDef(module, elem);
                const len = arrayTypeLen(module, md);
                const elem_is_struct = ed != null and ed.?.op == .TypeStruct;
                const elem_is_aggregate = ed != null and (ed.?.op == .TypeArray or ed.?.op == .TypeRuntimeArray or ed.?.op == .TypeMatrix);
                if (elem_is_aggregate) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL output-block flattening does not support an array of arrays/matrices at a @location", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const etype = if (!elem_is_struct) try wgslType(module, elem, names, arena) else "";
                var k: u32 = 0;
                while (k < len) : (k += 1) {
                    const ef = try std.fmt.allocPrint(arena, "{s}_{d}", .{ child_flat, k });
                    const es = try std.fmt.allocPrint(arena, "{s}[{d}]", .{ child_src, k });
                    if (elem_is_struct) {
                        try collectOutputLeaves(module, names, elem, ef, es, leaves, arena);
                    } else {
                        try leaves.append(arena, .{ .flat_name = ef, .type_name = etype, .is_int = isIntegerWgslType(etype), .src = es });
                    }
                }
            },
            .TypeMatrix => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL output-block flattening does not support a matrix member at a @location", .{}) catch null;
                return error.UnsupportedOp;
            },
            else => {
                const mtype = try wgslType(module, mt_id, names, arena);
                try leaves.append(arena, .{ .flat_name = child_flat, .type_name = mtype, .is_int = isIntegerWgslType(mtype), .src = child_src });
            },
        }
    }
}

/// For a #170-A2 widened uniform array member, resolve the WGSL scalar base
/// name (`f32`/`i32`/`u32`) of the innermost element. The element is widened to
/// `vec4<base>`. `elem_type_id` is the array's element type (scalar, vec2, or a
/// nested array whose innermost element is scalar/vec2). Falls back to `f32`.
fn wrappedVec4ElemType(module: *const ParsedModule, elem_type_id: u32) []const u8 {
    var cur = elem_type_id;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        const d = getDef(module, cur) orelse break;
        switch (d.op) {
            .TypeArray, .TypeRuntimeArray, .TypeVector => {
                if (d.words.len > 2) cur = d.words[2] else break;
            },
            .TypeFloat => return "f32",
            .TypeInt => {
                const signed = d.words.len > 3 and d.words[3] == 1;
                return if (signed) "i32" else "u32";
            },
            else => break,
        }
    }
    return "f32";
}

fn emitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap, wrapped_members: *const WrappedUniformMemberMap) !void {
    const inst = getDef(module, root_type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            try emitOneStructForwardDecl(module, names, root_type_id, w, alloc, emitted, emitted_names, atomic_fields, wrapped_members);
        },
        .TypePointer => if (inst.words.len > 3) try emitStructForwardDecls(module, names, inst.words[3], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members),
        .TypeArray => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members),
        else => {},
    }
}

fn emitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap, wrapped_members: *const WrappedUniformMemberMap) !void {
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
                        try emitOneStructForwardDecl(module, names, cur_id, w, alloc, emitted, emitted_names, atomic_fields, wrapped_members);
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
        // #170 A2: a sub-16 array element in a UNIFORM block is widened to vec4.
        // The matching swizzle is injected at the access site (buildAccessExprPlain).
        const wrap_kind: ?WrappedUniformMemberKind = wrapped_members.get(.{ .struct_id = type_id, .member_idx = @intCast(mi) });

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
                const li = getDef(module, mi2.words[3]);
                const lv: u32 = if (li) |l| l.words[3] else 1;
                // #170 A2: widen a sub-16 element to vec4<base> for uniform-space
                // alignment. The base scalar (f32/i32/u32) is read from the array's
                // innermost element; the swizzle is appended at the access site.
                if (wrap_kind != null) {
                    const vbase = wrappedVec4ElemType(module, mi2.words[2]);
                    try w.print("    {s}: array<vec4<{s}>, {d}>,\n", .{ mname, vbase, lv });
                    continue;
                }
                const et = try wgslType(module, mi2.words[2], names, alloc);
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
            // Array-ness comes from the Arrayed operand (word[5]), NOT from `dim`
            // (Dim is never 4 for arrays — 4 = Rect). A non-depth arrayed texture
            // (sampler2DArray, samplerCubeArray, sampler1DArray) MUST be spelled
            // texture_2d_array<T> / texture_cube_array<T> / texture_1d_array<T>;
            // emitting the non-array form makes naga reject the sample (coordinate
            // dimension mismatch). See arrayedSampleShape for the matching layer
            // split at the call sites.
            const arrayed_nondepth = inst.words.len > 5 and inst.words[5] == 1;
            const tex_type: []const u8 = if (arrayed_nondepth) switch (dim) {
                0 => "texture_1d_array",
                1 => "texture_2d_array",
                3 => "texture_cube_array",
                else => "texture_2d_array",
            } else switch (dim) {
                0 => "texture_1d",
                1 => "texture_2d",
                2 => "texture_3d",
                3 => "texture_cube",
                6 => "texture_2d",
                else => "texture_2d",
            };
            // Dim=Buffer (GLSL samplerBuffer / imageBuffer, OpTypeImage Dim=5) has
            // NO WGSL equivalent — `texture_buffer<T>` is not a real WGSL type and
            // naga rejects it. Fail loud instead of emitting a silent-wrong-shaped
            // type name (covers both the sampled and storage texel-buffer paths).
            if (dim == 5) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no texel buffer / texture_buffer type", .{}) catch null;
                return error.UnsupportedOp;
            }
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
                // The access mode normally tracks the GLSL readonly/writeonly
                // qualifier, which lives in the NonWritable/NonReadable
                // decorations on the *variable* — invisible from the type id
                // alone. The binding-emission site (which knows the variable)
                // calls wgslStorageTextureType directly with the resolved mode;
                // reaching wgslType here (e.g. a storage image nested in some
                // other type, with no variable context) falls back to
                // `read_write`, matching the Sampled=2 operand. See
                // wgslStorageTextureType for the texel-format and dim logic.
                break :blk try wgslStorageTextureType(module, type_id, "read_write", alloc);
            } else if (is_ms) {
                // WGSL spells the multisampled 2D texture `texture_multisampled_2d<T>`
                // (NOT `texture_2d_multisampled<T>`), and has NO multisampled 3D/cube
                // /array texture. A multisampled ARRAY (sampler2DMSArray) is therefore
                // unrepresentable — fail loud rather than emit an invalid type name.
                const ms_arrayed = inst.words.len > 5 and inst.words[5] == 1;
                if (ms_arrayed) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no multisampled array texture (sampler2DMSArray)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                break :blk std.fmt.allocPrint(alloc, "texture_multisampled_2d<{s}>", .{st}) catch "texture_multisampled_2d<f32>";
            } else {
                // WGSL has NO 1D-array sampled texture (`texture_1d_array` is not
                // a real WGSL type — only 2d/2d_array/3d/cube/cube_array and the
                // non-array 1d exist). A GLSL sampler1DArray cannot be lowered;
                // fail loud rather than emit an invalid type name that naga
                // rejects downstream (matches the storage 1D-array guard).
                if (dim == 0 and arrayed_nondepth) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no 1D-array texture (sampler1DArray)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                break :blk std.fmt.allocPrint(alloc, "{s}<{s}>", .{ tex_type, st }) catch "texture_2d<f32>";
            }
        },
        .TypeSampledImage => if (inst.words.len > 2) try wgslType(module, inst.words[2], names, alloc) else "texture_2d<f32>",
        else => "vec4f",
    };
}

/// Build the WGSL storage-texture type for an OpTypeImage, with the access mode
/// supplied by the caller (`read` / `write` / `read_write`). The access mode
/// cannot be inferred from the image type alone — GLSL `readonly` / `writeonly`
/// lower to NonWritable / NonReadable decorations on the *variable*, so the
/// binding-emission site (which knows the variable) resolves it via
/// `storageAccessMode` and passes it here. `write` is the only core-WGSL storage
/// access; `read` / `read_write` require the readonly_and_readwrite_storage_textures
/// language feature, so honoring the qualifier keeps the output as portable as
/// the source allows.
fn wgslStorageTextureType(module: *const ParsedModule, image_type_id: u32, access_mode: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, image_type_id) orelse return error.UnsupportedOp;
    const dim = if (inst.words.len > 3) inst.words[3] else 1;
    const sampled_type_id = inst.words[2];
    const arrayed_nondepth = inst.words.len > 5 and inst.words[5] == 1;
    // Dim=Buffer (imageBuffer, Dim=5) has no WGSL texel-buffer equivalent —
    // fail loud rather than emit an invalid type (mirrors the wgslType guard).
    if (dim == 5) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no texel buffer / texture_buffer type", .{}) catch null;
        return error.UnsupportedOp;
    }
    // The WGSL texel format comes from the SPIR-V ImageFormat operand (word 8),
    // NOT a hardcoded rgba8unorm — an `r32i` image must be
    // `texture_storage_2d<r32sint, …>` so its textureLoad returns vec4<i32>
    // (else naga rejects the typed result). For an Unknown or non-WGSL-storage
    // format, fall back to a COMPONENT-correct r32 format keyed off the image's
    // sampled type (sint/uint/float) so the load's component type still matches
    // its annotation; the channel count may be approximate, but it is never
    // silently a float format for an integer image (the silent-wrong this fixes).
    const img_fmt = if (inst.words.len > 8) inst.words[8] else 0;
    const texel: []const u8 = spirvImageFormatToWgsl(img_fmt) orelse fallback: {
        const sti = getDef(module, sampled_type_id) orelse break :fallback "rgba8unorm";
        if (sti.op == .TypeInt) {
            break :fallback if (sti.words.len > 3 and sti.words[3] == 0) "r32uint" else "r32sint";
        }
        break :fallback "rgba8unorm";
    };
    // WGSL storage textures: texture_storage_1d / _2d / _2d_array / _3d. There
    // is NO storage cube, NO 1d-array, NO multisampled storage — fail loud on
    // those rather than emit an invalid type.
    const storage_dim: []const u8 = switch (dim) {
        0 => if (arrayed_nondepth) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no 1D-array storage texture (image1DArray)", .{}) catch null;
            return error.UnsupportedOp;
        } else "texture_storage_1d",
        1 => if (arrayed_nondepth) "texture_storage_2d_array" else "texture_storage_2d",
        2 => "texture_storage_3d",
        3 => {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no storage cube texture (imageCube)", .{}) catch null;
            return error.UnsupportedOp;
        },
        else => "texture_storage_2d",
    };
    return std.fmt.allocPrint(alloc, "{s}<{s}, {s}>", .{ storage_dim, texel, access_mode });
}

/// Whether a WGSL type name (as produced by `wgslType`) is an integer scalar or
/// vector. WGSL forbids perspective/linear interpolation of such user-defined
/// IO, so any integer vertex output / fragment input MUST carry
/// `@interpolate(flat)` or downstream consumers (wgpu/Dawn) reject the pipeline.
/// `wgslType` spells integer vectors with the canonical short names
/// (vec2i/vec3i/vec4i, vec2u/vec3u/vec4u), never the `vecN<i32>` long form.
fn isIntegerWgslType(type_name: []const u8) bool {
    const names = [_][]const u8{
        "i32",   "u32",
        "vec2i", "vec3i", "vec4i",
        "vec2u", "vec3u", "vec4u",
    };
    for (names) |n| {
        if (std.mem.eql(u8, type_name, n)) return true;
    }
    return false;
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

/// WGSL storage-texture access mode for an image *variable*, derived from the
/// NonWritable (24) / NonReadable (25) decorations the GLSL `readonly` /
/// `writeonly` qualifiers lower to: `readonly` → NonWritable → "read",
/// `writeonly` → NonReadable → "write", neither → "read_write". A degenerate
/// readonly+writeonly image (both decorations) also maps to "read_write" — WGSL
/// has no no-access mode, and read_write is the safe superset.
fn storageAccessMode(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), var_id: u32) []const u8 {
    const non_writable = hasDec(decs, var_id, .non_writable);
    const non_readable = hasDec(decs, var_id, .non_readable);
    if (non_writable and !non_readable) return "read";
    if (non_readable and !non_writable) return "write";
    return "read_write";
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

    // Post-process: type SCALAR float constant literals concretely (#170 G5).
    // naga rejects all-constant-arg builtin calls whose args are abstract
    // (e.g. `smoothstep(0.08, 0.03, 1.0)` → "Abstract types may only appear in
    // constant expressions"). Suffixing a scalar float literal with `f` types it
    // concretely, which naga accepts in all contexts. SCALAR FLOAT ONLY — the
    // composite path already emits concrete `vec3<f32>(...)`/`mat..` forms, and
    // bare abstract INTs coerce fine in the contexts they appear (typing them
    // with `i` instead regressed correct, already-passing output such as the
    // `textureGather` component index and inline arithmetic literals). We
    // re-derive the literal here (so a name overwritten by an OpName alias is
    // left alone) and only rewrite a plain numeric literal.
    {
        var lit_reps = std.ArrayList(struct { key: u32, val: []const u8 }).initCapacity(alloc, 16) catch return;
        defer lit_reps.deinit(alloc);
        for (module.instructions) |inst| {
            if (inst.op != .Constant or inst.words.len <= 3) continue;
            const rid = inst.words[2];
            const ti = getDef(module, inst.words[1]) orelse continue;
            if (ti.op != .TypeFloat) continue; // scalar float only
            // #252: WGSL has no inf/nan literal. A non-finite 32-bit float constant
            // (e.g. an overflowing `1e40` → +inf, or a folded `0.0/0.0` → NaN) is
            // named by the shared formatter as the bare `inf`/`-inf`/`nan` identifier,
            // which naga rejects ("no definition in scope"). Emit the exact bit
            // pattern via `bitcast<f32>(0x..u)` instead.
            if (ti.words.len > 2 and ti.words[2] == 32) {
                const f: f32 = @bitCast(inst.words[3]);
                if (!std.math.isFinite(f)) {
                    const bc = std.fmt.allocPrint(alloc, "bitcast<f32>(0x{x:0>8}u)", .{inst.words[3]}) catch continue;
                    lit_reps.append(alloc, .{ .key = rid, .val = bc }) catch alloc.free(bc);
                    continue;
                }
            }
            const cur = names.get(rid) orelse continue;
            if (!isPlainNumericLiteral(cur)) continue; // OpName alias / already typed
            const typed = std.fmt.allocPrint(alloc, "{s}f", .{cur}) catch continue;
            lit_reps.append(alloc, .{ .key = rid, .val = typed }) catch {
                alloc.free(typed);
                continue;
            };
        }
        for (lit_reps.items) |r| {
            if (names.fetchPut(r.key, r.val) catch null) |old| alloc.free(old.value);
        }
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
fn memberHasFlat(module: *const ParsedModule, struct_id: u32, member_index: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 4 and
            inst.words[1] == struct_id and inst.words[2] == member_index)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .flat) return true;
        }
    }
    return false;
}

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

/// Read the ArrayStride decoration (6) off an ARRAY TYPE id. Unlike row_major /
/// flat (which are `OpMemberDecorate` on the enclosing struct), ArrayStride is an
/// `OpDecorate` on the array type id itself — mirror reflection.zig's lookup
/// (`astrides`: array TYPE id → ArrayStride). Returns null if undecorated.
fn arrayTypeStride(module: *const ParsedModule, array_type_id: u32) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 4 and
            inst.words[1] == array_type_id and
            inst.words[2] == @intFromEnum(spirv.Decoration.array_stride))
        {
            return inst.words[3];
        }
    }
    return null;
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
fn buildAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator, wrapped_members: *const WrappedUniformMemberMap) ![]const u8 {
    if (indices.len != 0) {
        if (findRowMajorMatrix(module, base_id, indices)) |hit| {
            var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return error.OutOfMemory;
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, "transpose(");
            const inner = try buildAccessExprPlain(module, names, base_id, indices[0 .. hit.boundary + 1], alloc, wrapped_members);
            defer alloc.free(inner);
            try buf.appendSlice(alloc, inner);
            try buf.appendSlice(alloc, ")");
            try appendMatrixTail(module, names, hit.matrix_tid, indices[hit.boundary + 1 ..], &buf, alloc);
            return buf.toOwnedSlice(alloc);
        }
    }
    return buildAccessExprPlain(module, names, base_id, indices, alloc, wrapped_members);
}

fn buildAccessExprPlain(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator, wrapped_members: *const WrappedUniformMemberMap) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) return try alloc.dupe(u8, base_name);

    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_name);

    var current_type_id: ?u32 = resolvePointee(module, base_id);

    // #170 A2: when descending through a wrapped uniform array member, the leaf
    // element was widened to vec4; the swizzle (`.x`/`.xy`) is appended once the
    // immediately-following array index reaches the element. GUARD: the disjoint
    // whole-UBO bare-array wrapper (`._wrapped_`) appends its own `.x` in the
    // caller, so we skip injection on those bases.
    const skip_wrap = std.mem.indexOf(u8, base_name, "._wrapped_") != null;
    var pending_swizzle: ?[]const u8 = null;

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
                    // Record a pending swizzle if this member's array element was
                    // widened to vec4 in the uniform struct (resolved on the
                    // struct type id BEFORE we advance current_type_id below).
                    if (!skip_wrap) {
                        if (wrapped_members.get(.{ .struct_id = current_type_id.?, .member_idx = val })) |k|
                            pending_swizzle = k.swizzle();
                    }
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
                    // The array index that reaches the widened leaf — narrow it.
                    if (pending_swizzle) |sw| {
                        try buf.appendSlice(alloc, sw);
                        pending_swizzle = null;
                    }
                }
            } else {
                const idx_name = names.get(index_id) orelse "i";
                try buf.print(alloc, "[{s}]", .{idx_name});
                if (current_type_id) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| current_type_id = tinst.words[2];
                }
                // Dynamic array index reaching the widened leaf — narrow it.
                if (pending_swizzle) |sw| {
                    try buf.appendSlice(alloc, sw);
                    pending_swizzle = null;
                }
            }
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Try to resolve a constant expression to a WGSL literal string
fn resolveConstantExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32, arena: std.mem.Allocator) ?[]const u8 {
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .ConstantComposite => {
            // Build a WGSL composite constructor: `vec4f(e0,…)` for a vector,
            // `array<T, N>(e0, e1, …)` for a (possibly nested) array, recursing
            // into each constituent. Used so a const-initialised global emits
            // its real values (`const LUT: array<f32,16> = array<f32,16>(…)`)
            // instead of a zero-initialised var<private> (silent-wrong).
            if (inst.words.len < 3) return null;
            const type_name = wgslType(module, inst.words[1], names, arena) catch return null;
            var buf = std.ArrayList(u8).initCapacity(arena, 64) catch return null;
            buf.print(arena, "{s}(", .{type_name}) catch return null;
            for (inst.words[3..], 0..) |comp_id, i| {
                if (i > 0) buf.appendSlice(arena, ", ") catch return null;
                const comp = resolveConstantExpr(module, names, comp_id, arena) orelse return null;
                buf.appendSlice(arena, comp) catch return null;
            }
            buf.appendSlice(arena, ")") catch return null;
            return buf.toOwnedSlice(arena) catch return null;
        },
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
                    if (!std.math.isFinite(f)) {
                        // #252: WGSL has no inf/nan literal — emit the exact bits.
                        buf.print(arena, "bitcast<f32>(0x{x:0>8}u)", .{val}) catch return null;
                    } else if (f == @floor(f) and @abs(f) < 1e6) {
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

/// Resolve the sampler argument for a WGSL texture-sample call. When the SPIR-V
/// "sampled image" operand is an OpSampledImage built AT THE CALL SITE from a
/// SEPARATE texture + sampler (Vulkan `sampler2D(tex, samp)`), the real sampler
/// is its sampler operand (words[4]) — use that name (a standalone `var uS:
/// sampler;` global, or a function sampler parameter). Otherwise (a combined
/// sampler2D loaded directly, the common case) fall back to the texture's
/// implicit `<tex>_sampler` partner. The fallback keeps every combined-sampler
/// shader byte-identical; only the separate-sampler path changes.
fn resolveSamplerArg(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), sampled_image_id: u32, tex_name: []const u8, arena: std.mem.Allocator) []const u8 {
    if (getDef(module, sampled_image_id)) |d| {
        if (d.op == .SampledImage and d.words.len > 4) {
            if (names.get(d.words[4])) |sn| return sn;
        }
    }
    return std.fmt.allocPrint(arena, "{s}_sampler", .{tex_name}) catch tex_name;
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

/// Scan for OpAtomic* RMW ops whose pointer operand is a Workgroup (or Private)
/// OpVariable DIRECTLY — a GLSL `shared` SCALAR that is an atomic target (an SSBO
/// struct member goes through collectAtomicFields instead). WGSL requires such a
/// variable to be declared `atomic<T>` and its plain OpLoad/OpStore lowered to
/// atomicLoad/atomicStore (a bare `var<workgroup> s: u32` + `atomicAdd(&s, …)` is
/// naga-rejected: "atomic operation is done on a pointer to a non-atomic").
fn collectAtomicVars(module: *const ParsedModule, out: *std.AutoHashMap(u32, void)) !void {
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
        const ptr_inst = common.getDef(module, inst.words[3]) orelse continue;
        if (ptr_inst.op != .Variable or ptr_inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(ptr_inst.words[3]);
        // Workgroup only: the decl-wrapping below rewrites `var<workgroup>` to
        // `atomic<T>`. A Private-storage atomic target would get its load/store
        // rewritten to atomicLoad/atomicStore WITHOUT an atomic<> decl (mismatch),
        // but GLSL has no construct that produces a Private-storage atomic target,
        // so restricting here keeps the load/store rewrites consistent with the
        // decl. (Review follow-up.)
        if (sc == .Workgroup) {
            try out.put(inst.words[3], {});
        }
    }
}

/// Classify a uniform struct's array members that need vec4-widening (#170 A2).
/// `struct_type_id` is the *resolved* pointee struct of a uniform (non-SSBO)
/// cbuffer. For each member that is a (possibly nested) array whose innermost
/// element is a sub-16 scalar (f32/i32/u32, .x) or vec2 (.xy), record the
/// swizzle needed to re-narrow the widened element. vec3/vec4/matrix elements
/// are already 16-aligned and are NOT recorded.
///
/// Nested *sub-struct* array members are NOT recursed into here (deferred —
/// see #170): only the direct members of the uniform struct are classified.
///
/// DEFERRED (honest, not silent-wrong): a whole-array-member LOAD of a wrapped
/// member (e.g. passing `u.arr` to a function taking `float a[N]`) drops the
/// per-element swizzle and emits `array<vec4<f32>,N>` where `array<f32,N>` is
/// expected → naga surfaces a TYPE error. That is honest-loud (caught by naga),
/// not silent-wrong, so it is left for a follow-up; only indexed element reads
/// (`u.arr[i]` → `.x`/`.xy`) are lowered correctly today.
fn collectWrappedUniformMembersForStruct(module: *const ParsedModule, struct_type_id: u32, out: *WrappedUniformMemberMap) !void {
    const sdef = getDef(module, struct_type_id) orelse return;
    if (sdef.op != .TypeStruct or sdef.words.len <= 2) return;
    for (sdef.words[2..], 0..) |mt_id, mi| {
        // Only single-level sized/runtime arrays are handled. Multi-dimensional
        // arrays (`float a[2][3]`) and arrays-of-sub-struct are DEFERRED (#170):
        // their widened element type would need recursive nesting that the
        // current emit/access plumbing does not yet build correctly.
        const md = getDef(module, mt_id) orelse continue;
        if (md.op != .TypeArray and md.op != .TypeRuntimeArray) continue;
        if (md.words.len <= 2) continue;
        // CORRECTNESS GATE (#170 review): only wrap when the SOURCE array's
        // ArrayStride is 16. std140 ALWAYS rounds an array-element stride up to
        // 16, so the host packs the scalar/vec2 at byte 0 of each 16-byte slot —
        // exactly where the widened `arr[i].x`/`.xy` reads it. A stride of 4 or 8
        // (scalar-block-layout `scalar` / std430 UNIFORM) means the host packs
        // elements TIGHTLY (0,4,8,12); wrapping to vec4 then reads bytes
        // 0,16,32,48 → WRONG DATA, which naga ACCEPTS (silent-wrong). When the
        // stride is not 16 we DON'T record the member: it falls through to the
        // unwrapped `array<base,N>` emission, which naga rejects loudly (honest),
        // matching `main`'s behavior. (SSBOs are already excluded by the caller's
        // `!cb.is_ssbo` filter; this guards scalar/std430 UNIFORM blocks.)
        if (arrayTypeStride(module, mt_id) != 16) continue;
        const elem_id = md.words[2];
        const ed = getDef(module, elem_id) orelse continue;
        // If the element is itself an array, it is a multi-dim array → defer.
        if (ed.op == .TypeArray or ed.op == .TypeRuntimeArray) continue;
        const kind: ?WrappedUniformMemberKind = switch (ed.op) {
            // Scalar float/int element (4 bytes) → widen to vec4, narrow with .x.
            .TypeFloat, .TypeInt => .x,
            // Vector element: only vec2 (8 bytes) needs widening. vec3/vec4 are
            // already 16-aligned (vec3 is padded to 16 in std140/std430).
            .TypeVector => blk: {
                const comp_count = if (ed.words.len > 3) ed.words[3] else 0;
                break :blk if (comp_count == 2) .xy else null;
            },
            else => null,
        };
        if (kind) |k| {
            try out.put(.{ .struct_id = struct_type_id, .member_idx = @intCast(mi) }, k);
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
        // Composite constants carry their result type in words[1] too — needed so
        // an OpCompositeExtract from an inline `array<...>(...)` constant is typed
        // as an array (indexed `[i]`), not swizzled `.x`.
        .ConstantComposite, .SpecConstantComposite,
        .Constant, .ConstantTrue, .ConstantFalse, .SpecConstant,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast, .QuantizeToF16,
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
        .LogicalAnd, .LogicalOr, .LogicalEqual, .LogicalNotEqual,
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
        else => {
            // OpIAddCarry (149) / OpISubBorrow (150) carry their {result,carry|borrow}
            // struct type in words[1] (like the named binary ops above) but `spirv.Op`
            // does not name them, so they cannot be a switch prong. Reporting the
            // struct type here makes the `src_is_struct` guards (emit path + dead-
            // extract pre-scan) correctly suppress the vector-swizzle collapse of
            // their member extracts. (#170)
            if (isAddCarryOrSubBorrow(inst.op) and inst.words.len > 1) return inst.words[1];
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn spirvToWGSL(alloc: std.mem.Allocator, spirv_words_in: []const u32, options: WgslCompileOptions) ![]const u8 {
    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V (no-op on
    // structured input; fall back to the original on failure — see spirvToGLSL).
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words_in) catch null;
    defer if (_norm) |n| alloc.free(n);
    const spirv_words = _norm orelse spirv_words_in;
    last_error_detail = null; // clear any detail from a prior compile on this thread
    needs_inverse_2 = false;
    needs_inverse_3 = false;
    needs_inverse_4 = false;
    var module = try common.parseModule(alloc, spirv_words);
    defer module.deinit(alloc);

    // Override entry point if requested
    if (!std.mem.eql(u8, options.entry_point_name, "main")) {
        if (common.findEntryPoint(&module, options.entry_point_name)) |ep_id| {
            module.entry_point_id = ep_id;
        } else return error.EntryPointNotFound;
    }

    // WGSL has only vertex / fragment / compute entry points. Geometry,
    // tessellation, mesh/task and ray-tracing stages cannot be represented at
    // all — fail loud with a named error rather than emit WGSL that naga rejects
    // (the silent-wrong this milestone forbids).
    switch (module.execution_model) {
        .Vertex, .Fragment, .GLCompute => {},
        else => {
            last_error_detail = std.fmt.bufPrint(
                &last_error_detail_buf,
                "WGSL has no '{s}' entry point (WGSL supports only vertex/fragment/compute)",
                .{@tagName(module.execution_model)},
            ) catch null;
            return error.UnsupportedStage;
        },
    }

    // WGSL has no ARM tensors (SPV_ARM_tensors: OpTypeTensorARM + OpTensor*ARM).
    // Without this guard the unmapped tensor ops fell through to a `var v`
    // fallback emitted repeatedly → naga "redefinition of `v`". Fail loud.
    for (module.instructions) |tinst| {
        if (tinst.op == .TypeTensorARM) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no ARM tensor type (SPV_ARM_tensors)", .{}) catch null;
            return error.UnsupportedOp;
        }
    }

    // WGSL has no ray queries (SPV_KHR_ray_query: OpTypeRayQueryKHR + rayQuery
    // ops). The unmapped ops otherwise fall through to a repeated `var v`
    // fallback → naga "redefinition of `v`". Fail loud.
    for (module.instructions) |rinst| {
        if (rinst.op == .TypeRayQueryKHR) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no ray-query type (SPV_KHR_ray_query)", .{}) catch null;
            return error.UnsupportedOp;
        }
    }

    // WGSL has no fragment-shader interlock (GL_ARB/EXT_fragment_shader_interlock:
    // beginInvocationInterlockARB/endInvocationInterlockARB). Detect the interlock
    // execution mode (PixelInterlock{Ordered,Unordered}EXT 5366/5367,
    // SampleInterlock{Ordered,Unordered}EXT 5368/5369) and fail loud rather than
    // emit WGSL that naga rejects. Compare the raw mode value (not @enumFromInt) so
    // an unknown vendor mode can never panic.
    for (module.instructions) |einst| {
        if (einst.op == .ExecutionMode and einst.words.len >= 3) {
            const mode_val = einst.words[2];
            if (mode_val >= 5366 and mode_val <= 5369) {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL has no fragment-shader interlock (GL_ARB_fragment_shader_interlock)",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            }
        }
    }

    // Separate comparison sampler: a depth-COMPARE op (OpImageSampleDref*/
    // OpImageDrefGather) whose sampled image is an OpSampledImage built AT THE
    // CALL SITE from a distinct texture + samplerShadow (Vulkan
    // `sampler2DShadow(tex, samp)`). WGSL pins depth-ness to the TEXTURE type
    // (texture_depth_2d + sampler_comparison), but such a texture is routinely
    // ALSO sampled non-compare (`sampler2D(tex, s)` returning vec4) — and a
    // texture binding cannot be both texture_depth_2d and texture_2d<f32>. The
    // backend does not route separate comparison samplers, so fail loud rather
    // than emit an undeclared `<tex>_sampler` (naga reject) or wrong types. A
    // COMBINED sampler2DShadow global (no call-site OpSampledImage) is unaffected
    // — it is handled by the texture's sampler_comparison partner.
    for (module.instructions) |inst| {
        const is_dref = switch (inst.op) {
            .ImageSampleDrefImplicitLod, .ImageSampleDrefExplicitLod,
            .ImageSampleProjDrefImplicitLod, .ImageSampleProjDrefExplicitLod,
            .ImageDrefGather,
            => true,
            else => false,
        };
        if (!is_dref or inst.words.len < 4) continue;
        const si = getDef(&module, inst.words[3]) orelse continue;
        if (si.op == .SampledImage) {
            last_error_detail = std.fmt.bufPrint(
                &last_error_detail_buf,
                "WGSL cannot represent a separate comparison sampler (sampler2DShadow built from a distinct texture + samplerShadow)",
                .{},
            ) catch null;
            return error.UnsupportedOp;
        }
    }


    // Built-ins with no representable standard-WGSL entry-point I/O form must fail
    // loud, not leak the identifier (naga reject) or get misclassified as a
    // `@location` varying:
    //   Layer=9 / ViewportIndex=10  — layered / multi-viewport rendering.
    //   ClipDistance=3 / CullDistance=4 — `array<f32,N>` built-ins; WGSL only
    //     allows numeric scalars/vectors as user I/O (naga: "The type [..]
    //     cannot be used for user-defined entry point inputs or outputs"), and
    //     `gl_CullDistance` has no WGSL analogue at all. We previously emitted
    //     `@location(N) gl_ClipDistance: array<f32, 8>`, which naga rejects.
    for (module.instructions) |dinst| {
        if (dinst.op == .Decorate and dinst.words.len >= 4 and
            dinst.words[2] == @intFromEnum(spirv.Decoration.built_in))
        {
            const bi = dinst.words[3];
            //   PointSize=1 — WGSL points always render at 1px; there is no
            //     point-size output. We previously emitted `@builtin(__point_size)`
            //     (an invented builtin), which naga rejects ("Identifier starts
            //     with a reserved prefix: `__point_size`"). The decoration only
            //     appears when the shader actually writes gl_PointSize, so this
            //     fails loud exactly for shaders that depend on a size WGSL cannot
            //     honor — rather than silently dropping it and rendering wrong.
            if (bi == 9 or bi == 10 or bi == 3 or bi == 4 or bi == 1) {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL has no {s} built-in",
                    .{switch (bi) {
                        9 => "layer (gl_Layer)",
                        10 => "viewport-index (gl_ViewportIndex)",
                        3 => "clip-distance (gl_ClipDistance) array",
                        4 => "cull-distance (gl_CullDistance) array",
                        else => "point-size (gl_PointSize)",
                    }},
                ) catch null;
                return error.UnsupportedOp;
            }
        }
    }

    // Scalar `refract` (GLSL.std.450 Refract=72 on a scalar) — WGSL's `refract`
    // is vector-only. Unlike normalize/length/distance/reflect (lowered inline by
    // scalarGeomLower), refract's formula is value-sensitive and naga only
    // type-checks, so a hand-rolled scalar version could pass naga while
    // computing the wrong value (silent-wrong). Fail loud instead.
    for (module.instructions) |xinst| {
        if (xinst.op == .ExtInst and xinst.words.len > 4 and xinst.words[4] == 72) {
            const rt_inst = getDef(&module, xinst.words[1]);
            if (rt_inst) |ti| {
                if (ti.op == .TypeFloat) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no scalar refract() (the builtin is vector-only)", .{}) catch null;
                    return error.UnsupportedOp;
                }
            }
        }
    }

    // Pre-emit scan for GLSL.std.450 MatrixInverse (34): WGSL has no inverse
    // builtin, so each used square size (2/3/4) needs its generated spvInverseN
    // helper written into the preamble exactly once. A non-square or unsupported
    // size leaves all flags clear; the ExtInst arm then honest-errors (no inverse
    // exists for a non-square matrix). Done upfront so the helper precedes every
    // call site — WGSL functions must be declared before use.
    for (module.instructions) |minst| {
        if (minst.op == .ExtInst and minst.words.len > 4 and minst.words[4] == 34) {
            if (inverseMatrixDim(&module, minst.words[1])) |dim| {
                switch (dim) {
                    2 => needs_inverse_2 = true,
                    3 => needs_inverse_3 = true,
                    4 => needs_inverse_4 = true,
                    else => {},
                }
            }
        }
    }

    // Descriptor sampler/image ARRAYS not yet supported by the WGSL backend
    // (would need binding_array) — fail loud rather than emit broken output.
    if (common.hasOpaqueArrayResource(&module)) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL backend does not yet support descriptor sampler/image arrays", .{}) catch null;
        return error.UnsupportedSamplerArray;
    }

    // WGSL forbids recursion — direct OR mutual (the spec disallows any cycle in
    // the call graph). Lenient front-ends can hand us a recursive SPIR-V call
    // graph; emitting it produces WGSL functions that call themselves, which naga
    // rejects ("declaration of `f` is recursive"). Fail loud rather than emit
    // illegal WGSL (the silent-wrong this backend forbids).
    if (callGraphHasCycle(&module, alloc)) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL forbids recursion (a direct or mutual function-call cycle)", .{}) catch null;
        return error.UnsupportedRecursion;
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

    // Emit-once generated matrix-inverse helper(s) flagged by the pre-emit scan
    // (WGSL has no inverse builtin). Written before any struct/function so they
    // are in scope at every call site.
    try writeInverseHelpers(w);

    const is_fragment = module.execution_model == .Fragment;
    const is_vertex = module.execution_model == .Vertex;
    const is_compute = module.execution_model == .GLCompute;
    var use_vertex_struct = false;

    // #170 (I): a spec-constant-sized array is unrepresentable in WGSL except as
    // a `var<workgroup>` type (override array sizing is workgroup-only). Any
    // OTHER variable — function-local, Private, or a UBO/SSBO whose struct has a
    // spec-const-sized member — therefore cannot be faithfully lowered: glslpp
    // would emit a runtime `array<T>` (naga-invalid as a local) or drop the
    // members to an empty struct. Fail loud instead. (Workgroup vars are skipped,
    // so a representable override-sized workgroup array is unaffected.)
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc == .Workgroup) continue;
        if (typeContainsSpecConstArray(&module, inst.words[1], 0)) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot size a non-workgroup array by a specialization constant (override array sizing is workgroup-only)", .{}) catch null;
            return error.UnsupportedOp;
        }
    }

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
                // GL_ARB_shader_stencil_export's gl_FragStencilRef has NO WGSL
                // equivalent (WGSL fragment shaders cannot write the stencil ref).
                // glslpp's SPIR-V emits it as an undecorated scalar-int Output, so
                // the backend would otherwise auto-assign it an @location and force
                // the int into a vec4f color slot (naga reject). Fail loud instead.
                // OpName preserves the GLSL builtin name, so match on it.
                if (names.get(inst.words[2])) |oname| {
                    if (std.mem.indexOf(u8, oname, "FragStencilRef") != null) {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no fragment stencil-ref output (gl_FragStencilRef)", .{}) catch null;
                        return error.UnsupportedOp;
                    }
                }
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
                const builtin_val = getDecVal(&decorations, inst.words[2], .built_in);
                const builtin: ?spirv.BuiltIn = if (builtin_val) |bv| @enumFromInt(bv) else null;
                // Collect EVERY stage input. A non-builtin input without an
                // explicit Location (e.g. GLSL `in vec4 inV;`) still needs to be
                // an entry-point parameter — the emit below auto-assigns
                // `@location(i)`. Dropping it (the old `location != null or
                // builtin != null` filter) left the body referencing an
                // undeclared identifier (invalid WGSL, naga reject).
                try input_vars.append(arena, .{ .id = inst.words[2], .type_id = inst.words[1], .builtin = builtin });
            }
        }
    }

    // WGSL requires every vertex entry to return a @builtin(position) value. A
    // vertex shader that never writes gl_Position cannot be lowered to valid
    // WGSL (naga: "Vertex shaders must return a @builtin(position) output").
    // Fabricating one would be silent-wrong, so fail loud with an honest error.
    if (is_vertex and output_vars.items.len > 0) {
        var has_position = false;
        for (output_vars.items) |ovid| {
            if (getDecVal(&decorations, ovid, .built_in)) |bv| {
                if (bv == @intFromEnum(spirv.BuiltIn.position)) {
                    has_position = true;
                    break;
                }
            }
        }
        if (!has_position) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL vertex shader requires a gl_Position (@builtin(position)) output", .{}) catch null;
            return error.UnsupportedOp;
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

    // Cross-function I/O (spec docs/specs/2026-06-02-wgsl-cross-function-io.md):
    // WGSL @location inputs are entry-point parameters, NOT module globals, so a
    // *helper* function that reads a stage input would reference an undefined
    // identifier (naga reject — the largest undef-identifier bucket). Detect
    // location (non-builtin) inputs that are loaded inside a non-entry function;
    // those get promoted to a module-scope `var<private>` bridged from the entry
    // parameter. Gated precisely: if none qualify, every emission path below is
    // byte-identical to before (zero regression risk).
    var promoted_inputs = std.AutoHashMap(u32, void).init(arena);
    {
        var input_id_set = std.AutoHashMap(u32, void).init(arena);
        for (input_vars.items) |iv| {
            // @location inputs are entry-param-only in WGSL, so a helper that
            // reads one needs the var<private> bridge. The SAME is true of input
            // BUILT-INS (e.g. gl_FragCoord is `@builtin(position)` — only the
            // entry param, not a global): a helper reading it hits the same
            // undefined-identifier reject. Bridge the builtins with a clean
            // var<private> form (frag_coord/front_facing — NO u32 coercion,
            // unlike vertex_index/instance_index, which take the `_b` path).
            const bridgeable = if (iv.builtin) |bi| switch (bi) {
                .frag_coord, .front_facing => true,
                else => false,
            } else true;
            if (bridgeable) input_id_set.put(iv.id, {}) catch {};
        }
        if (input_id_set.count() > 0) {
            var cur_fn: u32 = 0;
            var in_entry = false;
            for (module.instructions) |inst| {
                if (inst.op == .Function and inst.words.len >= 3) {
                    cur_fn = inst.words[2];
                    in_entry = (module.entry_point_id != null and cur_fn == module.entry_point_id.?);
                } else if (inst.op == .FunctionEnd) {
                    cur_fn = 0;
                    in_entry = false;
                } else if (cur_fn != 0 and !in_entry) {
                    // Pointer operand positions: Load/AccessChain base = words[3],
                    // Store target = words[1].
                    const ptr_id: ?u32 = switch (inst.op) {
                        .Load, .AccessChain, .CopyObject => if (inst.words.len > 3) inst.words[3] else null,
                        .Store => if (inst.words.len > 1) inst.words[1] else null,
                        else => null,
                    };
                    if (ptr_id) |pid| {
                        if (input_id_set.contains(pid)) promoted_inputs.put(pid, {}) catch {};
                    }
                }
            }
        }
    }

    // Cross-function OUTPUTS (mirror of promoted_inputs): a stage output WRITTEN
    // (or read) inside a non-entry helper references an identifier that, by
    // default, exists only as the entry function's local `var` — naga reject
    // ("no definition in scope"). Promote such an output to a module-scope
    // `var<private>` so helpers can write it; the entry returns it by name at
    // the end (the writes happen via the calls main makes). Scoped to the simple
    // SINGLE-color-output case — MRT / depth / vertex-struct outputs have their
    // own struct-return machinery and are left untouched (zero regression risk:
    // if nothing qualifies, every path below is byte-identical).
    var promoted_outputs = std.AutoHashMap(u32, void).init(arena);
    if (output_vars.items.len == 1 and output_var_id != null and depth_output_var_id == null) {
        const ovid = output_var_id.?;
        var cur_fn: u32 = 0;
        var in_entry = false;
        for (module.instructions) |inst| {
            if (inst.op == .Function and inst.words.len >= 3) {
                cur_fn = inst.words[2];
                in_entry = (module.entry_point_id != null and cur_fn == module.entry_point_id.?);
            } else if (inst.op == .FunctionEnd) {
                cur_fn = 0;
                in_entry = false;
            } else if (cur_fn != 0 and !in_entry) {
                const ptr_id: ?u32 = switch (inst.op) {
                    .Load, .AccessChain, .CopyObject => if (inst.words.len > 3) inst.words[3] else null,
                    .Store => if (inst.words.len > 1) inst.words[1] else null,
                    else => null,
                };
                if (ptr_id) |pid| {
                    if (pid == ovid) promoted_outputs.put(pid, {}) catch {};
                }
            }
        }
    }

    // Collect cbuffers and textures
    var cbuffers = std.ArrayList(struct { name: []const u8, type_id: u32, binding: u32, is_ssbo: bool, result_id: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // `access` is the WGSL storage-texture access mode (read / write /
    // read_write) resolved from the variable's NonWritable/NonReadable
    // decorations; it is only consulted when `is_storage` is true.
    var textures = std.ArrayList(struct { name: []const u8, binding: u32, image_type_id: u32, is_storage: bool, access: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Standalone Vulkan separate samplers (GLSL `uniform sampler uS;` — a bare
    // OpTypeSampler in UniformConstant, combined with a separate texture at each
    // `sampler2D(tex, samp)` call site). These have no implicit texture partner,
    // so unlike a combined sampler2D they were dropped here and never declared
    // (`var uS: sampler;`), leaving call args referencing an undeclared name.
    var samplers = std.ArrayList(struct { name: []const u8, binding: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;

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
            .PushConstant => {
                // WGSL has NO push_constant address space (naga 29.0.3 rejects both
                // `var<push_constant>` and `enable push_constant`). The representable
                // lowering is a plain uniform buffer. Push constants carry no
                // Binding/DescriptorSet decoration, so we INVENT one: default to
                // binding 0. The binding-dedup pass below resolves collisions by
                // keeping the first-emitted entry at its binding and bumping later
                // colliders. NOTE: because this binding is fabricated (and dedup may
                // renumber colliders), the WGSL @binding here is NOT guaranteed to
                // match any original GLSL set/binding when push constants are present.
                // Mirroring the .Uniform arm reuses all downstream machinery (struct
                // forward-decls, name-collision rename, `push.value0` access chains).
                const name = names.get(result_id) orelse "push";
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .binding = 0, .is_ssbo = false, .result_id = result_id });
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
                        try textures.append(arena, .{ .name = name, .binding = binding * 2 + set, .image_type_id = img_type_id, .is_storage = false, .access = "read_write" });
                    },
                    .TypeImage => {
                        if (pointee_inst.words.len > 7 and pointee_inst.words[7] == 2) is_storage = true;
                        // readonly/writeonly come from NonWritable/NonReadable on
                        // the VARIABLE (result_id), not the image type, so the
                        // access mode is resolved here where the variable is known.
                        const access = storageAccessMode(&decorations, result_id);
                        try textures.append(arena, .{ .name = name, .binding = binding * 2 + set, .image_type_id = pointee_type, .is_storage = is_storage, .access = access });
                    },
                    .TypeSampler => {
                        try samplers.append(arena, .{ .name = name, .binding = binding * 2 + set });
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
        // Check if this Private var is actually used. A direct OpLoad reads a
        // scalar/struct global; an OpAccessChain rooted at the var reads an
        // element (`arr[i]` for a const array). Both count as "used" — missing
        // the access-chain case skipped declaring const-array globals, leaving
        // `arr[i]` referencing an undeclared name (naga reject). Safe to declare
        // now that the initializer path below emits the real array values via
        // resolveConstantExpr (not a zero-initialised var<private>).
        var has_load = false;
        for (module.instructions) |check| {
            if (check.op == .Load and check.words.len > 3 and check.words[3] == result_id) {
                has_load = true;
                break;
            }
            if (check.op == .AccessChain and check.words.len > 3 and check.words[3] == result_id) {
                has_load = true;
                break;
            }
        }
        if (!has_load) continue;
        // Check for initializer (optional 5th word in OpVariable)
        if (inst.words.len > 4) {
            // Const-initialised global: emit its real values as a `const`. If we
            // can't materialise the initializer, DON'T fall through to a
            // zero-initialised `var<private>` (that would be the wrong values =
            // silent-wrong) — skip the declaration so the access fails loudly
            // (naga: undefined identifier) instead of silently reading zeros.
            const init_id = inst.words[4];
            if (resolveConstantExpr(&module, &names, init_id, arena)) |val| {
                // #252: a non-finite float is spelled `bitcast<f32>(0x..u)` (valid in
                // runtime expressions) but naga REJECTS `bitcast` in a const-expression
                // ("Not implemented as constant expression"). WGSL has no const-expr
                // form for inf/nan, so a module-scope `const` with a non-finite
                // component is unrepresentable — fail loud, don't emit a non-parsing const.
                if (std.mem.indexOf(u8, val, "bitcast<f32>(0x") != null) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot represent a non-finite float constant in a module-scope const initializer", .{}) catch null;
                    return error.UnsupportedOp;
                }
                try w.print("const {s}: {s} = {s};\n", .{ name, rt, val });
            }
            continue;
        }
        try w.print("var<private> {s}: {s};\n", .{ name, rt });
    }

    // Promoted cross-function inputs: emit each as a module-scope var<private>
    // (the entry wrapper copies the @location parameter into it; see param
    // emission + body-start copy below). Helper functions then reference the
    // global by its existing name, which is now in scope.
    if (promoted_inputs.count() > 0) {
        for (input_vars.items) |iv| {
            if (!promoted_inputs.contains(iv.id)) continue;
            const name = names.get(iv.id) orelse continue;
            var actual_type = iv.type_id;
            if (getDef(&module, iv.type_id)) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
            }
            const rt = wgslType(&module, actual_type, &names, arena) catch continue;
            try w.print("var<private> {s}: {s};\n", .{ name, rt });
        }
    }

    // Promoted cross-function output: emit the module-scope var<private> so
    // helper functions can write it (the entry returns it by name). The local
    // `var` decl in the entry body is suppressed below (skip_output_var_decl).
    if (promoted_outputs.count() > 0) {
        const ovid = output_var_id.?;
        const name = names.get(ovid) orelse "out";
        var actual_type = getDef(&module, ovid).?.words[1];
        if (getDef(&module, actual_type)) |pi| {
            if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
        }
        const rt = wgslType(&module, actual_type, &names, arena) catch unreachable;
        try w.print("var<private> {s}: {s};\n", .{ name, rt });
    }

    // Detect SSBO struct fields that are the target of OpAtomic* ops.
    // WGSL requires such fields to be declared as `atomic<T>` (or `array<atomic<T>>`
    // when the atomic op indexes into an array field). naga rejects atomic ops on
    // non-atomic typed members with: "atomic operation is done on a pointer to a non-atomic".
    var atomic_fields = AtomicFieldMap.init(arena);
    defer atomic_fields.deinit();
    collectAtomicFields(&module, &atomic_fields) catch {};

    // #170 (F): GLSL `shared` scalars that are direct atomic targets must be
    // declared `atomic<T>` and their plain load/store lowered to atomicLoad/
    // atomicStore. Empty for shaders with no workgroup-scalar atomics, so all
    // other shaders are byte-identical.
    var atomic_vars = std.AutoHashMap(u32, void).init(arena);
    collectAtomicVars(&module, &atomic_vars) catch {};

    // Detect sub-16 array members of UNIFORM (non-SSBO) blocks (#170 A2). Such
    // members are widened to array<vec4<T>> at emission and swizzled at access
    // (see WrappedUniformMemberMap). SSBOs tolerate sub-16 strides → skipped.
    // Keyed by the resolved struct type id (same key space as atomic_fields and
    // the `type_id` passed to emitOneStructForwardDecl / buildAccessExprPlain's
    // current_type_id walk).
    var wrapped_uniform_members = WrappedUniformMemberMap.init(arena);
    defer wrapped_uniform_members.deinit();
    for (cbuffers.items) |cb| {
        if (cb.is_ssbo) continue;
        // cb.type_id may be a TypePointer (resolve to the pointee struct) or
        // already the pointee struct id, depending on the registration path.
        var struct_id = cb.type_id;
        if (getDef(&module, struct_id)) |pi| {
            if (pi.op == .TypePointer and pi.words.len > 3) struct_id = pi.words[3];
        }
        collectWrappedUniformMembersForStruct(&module, struct_id, &wrapped_uniform_members) catch {};
    }
    // Empty wrap-map for NON-uniform struct emission (local/function/workgroup
    // structs are not in uniform space, so their array members are never wrapped).
    var no_wrapped_members = WrappedUniformMemberMap.init(arena);
    defer no_wrapped_members.deinit();

    // Emit struct forward declarations for types used in cbuffers
    var emitted_structs = std.AutoHashMap(u32, void).init(arena);
    defer emitted_structs.deinit();
    var emitted_names = std.StringHashMap(void).init(arena);
    defer emitted_names.deinit();

    // #170 (A3): a GLSL `in Block { … } inst;` stage-input interface block is
    // emitted below (near `fn main`) as the @location-decorated entry-parameter
    // struct. But the body's whole-struct `OpLoad %Block %inst` ALSO makes the
    // generic forward-decl scans (function-body / cbuffer / local) emit a plain,
    // un-decorated `struct Block { … }` — so the type lands twice and naga
    // rejects the WGSL ("redefinition of `Block`"). Pre-seed those struct ids
    // (and names) into the emitted-sets so ONLY the IO-decorated version below is
    // written. Uses the SAME `ioBlockStructType` predicate as the emit path, so
    // the suppress side and emit side cannot drift. Gated precisely: when no
    // non-builtin stage input has a TypeStruct pointee, the sets are untouched
    // and every existing emission path is byte-identical.
    //
    // DUAL-USE GUARD: if the same struct is ALSO reachable as a data member of a
    // UBO/SSBO, suppressing the plain decl would leave the uniform referencing a
    // struct whose only definition carries @location — invalid WGSL that the
    // naga CLI leniently accepts but Tint/Dawn reject (a silent-wrong). That case
    // was already a loud "redefinition" reject before this change; keep it loud
    // by NOT pre-seeding (the dual emit returns, naga rejects) rather than
    // emitting silently-wrong @location-on-uniform. A full fix (a renamed IO
    // struct) is deferred — no corpus shader hits this.
    for (input_vars.items) |iv| {
        const sty = ioBlockStructType(&module, iv.type_id, iv.builtin) orelse continue;
        var data_used = false;
        for (cbuffers.items) |cb| {
            if (typeReachesStruct(&module, cb.type_id, sty, 0)) {
                data_used = true;
                break;
            }
        }
        if (data_used) continue;
        if ((try emitted_structs.fetchPut(sty, {})) == null) {
            if (names.get(sty)) |sname| try emitted_names.put(sname, {});
        }
    }

    for (cbuffers.items) |cb| {
        try emitStructForwardDecls(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &wrapped_uniform_members);
        try emitOneStructForwardDecl(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &wrapped_uniform_members);
    }

    // Emit struct forward declarations for types used as local variables
    var local_structs = std.AutoHashMap(u32, void).init(arena);
    defer local_structs.deinit();
    // Scan for Function-scoped variables AND Private globals. A module-scope
    // `const`/`var<private>` whose (possibly nested-array) element type is a
    // struct (e.g. `const foos: array<Foo, 2>`) is emitted above WITHOUT its
    // `struct Foo { … }` decl — that decl was only gathered for Function-scope
    // vars, so `Foo` was referenced but never declared (naga "no definition in
    // scope"). naga accepts module-scope forward references, so emitting the
    // struct here (after the global) is fine.
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function or sc == .Private) {
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
                                try emitOneStructForwardDecl(&module, &names, tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
                            }
                        }
                    }
                }
            }
        }
    }

    // Deduplicate bindings: auto-assign sequential bindings when multiple uniforms collide.
    // The first entry (ci == 0) always keeps its binding; only LATER entries that collide
    // with an already-seen binding are bumped to the next free slot. So whichever block is
    // emitted first keeps binding 0 (e.g. a push-constant block fabricated at binding 0 keeps
    // it iff it is emitted before any real UBO that also claims 0).
    // CAVEAT: WGSL binding numbers are therefore NOT guaranteed to match the original GLSL
    // set/binding when push constants are present (WGSL has no push_constant address space, so
    // a binding is invented) or when two declarations collide (the later one is renumbered).
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

    // #170 (H): vertex `out matNxM` outputs flattened into N column @location
    // members. Populated during VertexOutput field construction; consumed at the
    // Store site (emitBody) to split a whole-matrix write into per-column writes.
    var matrix_outputs = std.AutoHashMap(u32, MatrixOutput).init(arena);

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
                        // Mirror the workgroup-rename path (~below): fetchPut so we
                        // free the previous heap-allocated name. Every value in
                        // `names` is alloc-owned (collectNames dupes; the defer at
                        // map init frees each with alloc.free), so freeing the old
                        // value is safe and never touches a borrowed literal.
                        if (try names.fetchPut(vinst.words[2], new_name)) |old| alloc.free(old.value);
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
                        var var_name = names.get(inst.words[2]) orelse "shared";
                        // WGSL forbids a variable sharing its name with its struct
                        // type. A GLSL `shared` block with no instance name yields a
                        // struct AND a var both named e.g. `first` → naga rejects
                        // "redefinition of `first`". Rename the variable in `names`
                        // (body references resolve through it) so the type keeps its
                        // name.
                        if (std.mem.eql(u8, var_name, type_name)) {
                            const renamed = std.fmt.allocPrint(alloc, "{s}_wg", .{var_name}) catch null;
                            if (renamed) |rn| {
                                if (names.fetchPut(inst.words[2], rn) catch null) |old| alloc.free(old.value);
                                var_name = names.get(inst.words[2]) orelse rn;
                            }
                        }
                        // Emit struct declaration for array element types
                        try emitOneStructForwardDecl(&module, &names, pointee_type, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
                        // #170 (F): a `shared` scalar that is a direct atomic target
                        // must be `atomic<T>` (else naga rejects the atomic op).
                        const wg_type: []const u8 = if (atomic_vars.contains(inst.words[2]))
                            (std.fmt.allocPrint(arena, "atomic<{s}>", .{type_name}) catch type_name)
                        else
                            type_name;
                        try w.print("var<workgroup> {s}: {s};\n\n", .{ var_name, wg_type });
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
        // form (textureGatherCompare) is wired the same way — see the
        // ImageDrefGather arm, which splits the packed layer into its own
        // i32(round(...)) array_index argument.
        // Storage textures route through wgslStorageTextureType so the access
        // mode reflects the GLSL readonly/writeonly qualifier (resolved into
        // tex.access from the variable's decorations); the plain wgslType path
        // has no variable context and would emit read_write unconditionally.
        const tex_type = if (tex.is_storage)
            try wgslStorageTextureType(&module, tex.image_type_id, tex.access, arena)
        else
            try wgslType(&module, tex.image_type_id, &names, arena);
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

    // Emit standalone Vulkan separate samplers (`var uS: sampler;`). Each is
    // combined with a texture at the `sampler2D(tex, samp)` call site, where the
    // sample handlers resolve the sampler argument from the OpSampledImage's
    // sampler operand (see resolveSamplerArg). Bindings are allocated from the
    // same collision-avoiding pool as textures so they never alias.
    for (samplers.items) |samp| {
        var b = samp.binding;
        if (used_tex_bindings.contains(b)) {
            while (used_tex_bindings.contains(next_tex_binding)) : (next_tex_binding += 1) {}
            b = next_tex_binding;
            next_tex_binding += 1;
        }
        used_tex_bindings.put(b, {}) catch {};
        const shifted = common.applyBindingShift(b, options.binding_shift);
        const group = @divFloor(shifted, 2);
        try w.print("@group({d}) @binding({d})\nvar {s}: sampler;\n\n", .{ group, shifted, samp.name });
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
                // #252: a WGSL `override` default is a const-expression; a non-finite
                // float has no const-expr form (`bitcast` is rejected there too), so
                // fail loud rather than emit `= inf` (naga: undefined identifier).
                if (!std.math.isFinite(fv)) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot represent a non-finite float spec-constant (override) default", .{}) catch null;
                    return error.UnsupportedOp;
                }
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
                    try emitOneStructForwardDecl(&module, &names, fti.words[2], w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
                    // Also emit for param types
                    for (fti.words[3..]) |param_tid| {
                        try emitOneStructForwardDecl(&module, &names, param_tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
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
                    try emitOneStructForwardDecl(&module, &names, type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
                }
            }
        }
    }

    // Uniquify function names: GLSL permits overloading (same name, different
    // parameter types) but WGSL requires unique top-level function names. Each
    // OpFunctionCall targets a specific function id, and call sites resolve the
    // callee via names.get(fid), so renaming the names-map entry here also fixes
    // every call site — deterministic, with no risk of binding the wrong overload.
    {
        var fn_name_counts = std.StringHashMap(u32).init(alloc);
        defer fn_name_counts.deinit();
        for (func_ids.items) |fid| {
            const cur = names.get(fid) orelse continue;
            const gop = fn_name_counts.getOrPut(cur) catch continue;
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
                const uniq = std.fmt.allocPrint(alloc, "{s}_ov{d}", .{ cur, gop.value_ptr.* }) catch continue;
                if (names.fetchPut(fid, uniq) catch null) |old| alloc.free(old.value);
            } else {
                gop.value_ptr.* = 0;
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
        try emitBody(&module, &names, &decorations, fidx, w, alloc, arena, inout_ret_name, null, null, &wrapped_uniform_arrays, &wrapped_uniform_members, &matrix_outputs, &atomic_vars, .none);

        try w.writeAll("}\n\n");
    }

    // Emit VertexOutput struct if vertex shader has multiple outputs
    var vertex_output_fields = std.ArrayList(struct { name: []const u8, type_name: []const u8, builtin: ?[]const u8, location: ?u32, flat: bool }).initCapacity(arena, 4) catch return error.OutOfMemory;
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
        // Two outputs sharing a @location is GLSL dual-source blending
        // (`layout(location=0, index=0/1)`), which WGSL expresses with
        // `@blend_src(0/1)`. glslpp's SPIR-V currently drops the `Index`
        // decoration, so the backend cannot reconstruct which output is src0 vs
        // src1 — emitting two `@location(0)` is invalid (naga: "Multiple bindings
        // at location 0 are present"). Fail loud rather than emit it.
        for (output_vars.items, 0..) |a, ai| {
            const la = getDecVal(&decorations, a, .location) orelse ai;
            for (output_vars.items[ai + 1 ..]) |b| {
                const lb = getDecVal(&decorations, b, .location) orelse continue;
                if (la == lb) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL dual-source blending (two outputs at @location({d}); needs @blend_src) is not supported", .{la}) catch null;
                    return error.UnsupportedOp;
                }
            }
        }
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
    // Output interface blocks (`out Block {…} vout;`): a struct-typed output
    // var. WGSL forbids a nested struct field in an I/O struct, so flatten the
    // block's members into VertexOutput directly and alias the block var to
    // `vertex_out` (so the body's `vout.m` access becomes `vertex_out.m`).
    var io_block_outputs = std.AutoHashMap(u32, void).init(arena);
    // #170 (H): vertex OUTPUT interface blocks whose member is an aggregate
    // (array/struct/matrix) cannot live one-per-`@location`. Such a block is
    // reassembled into a local of its original (nested) type — the body writes
    // `io_<name>.member[i]` normally — its leaves are emitted as scalar/vector
    // `@location` members of VertexOutput, and each leaf is copied out before
    // return. `output_recons` keys the block var → local; `output_copyouts` is
    // the per-leaf copy-out list. Empty for any shader without such a block.
    const OutputRecon = struct { local_name: []const u8, type_name: []const u8, struct_type: u32 };
    var output_recons = std.AutoHashMap(u32, OutputRecon).init(arena);
    var output_copyouts = std.ArrayList(struct { flat: []const u8, src: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
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
            // A struct-typed (non-builtin) output is an interface block — flatten.
            const adef = getDef(&module, actual_type);
            if (builtin_val == null and adef != null and adef.?.op == .TypeStruct) {
                // #170 (H): a member is itself an aggregate (array/struct/matrix) —
                // deep-flatten the block into scalar/vector leaves and reassemble a
                // local for the body, copying each leaf out before return.
                if (blockHasAggregateMember(&module, actual_type)) {
                    const base: u32 = loc_val orelse 0;
                    const local = try std.fmt.allocPrint(arena, "io_{s}", .{var_name});
                    var leaves = std.ArrayList(OutputLeaf).initCapacity(arena, 4) catch return error.OutOfMemory;
                    try collectOutputLeaves(&module, &names, actual_type, "", local, &leaves, arena);
                    for (leaves.items, 0..) |leaf, li| {
                        try vertex_output_fields.append(arena, .{ .name = leaf.flat_name, .type_name = leaf.type_name, .builtin = null, .location = base + @as(u32, @intCast(li)), .flat = leaf.is_int });
                        try output_copyouts.append(arena, .{ .flat = leaf.flat_name, .src = leaf.src });
                    }
                    const tn = try wgslType(&module, actual_type, &names, arena);
                    try output_recons.put(ovid, .{ .local_name = local, .type_name = tn, .struct_type = actual_type });
                    continue;
                }
                try io_block_outputs.put(ovid, {});
                const base: u32 = loc_val orelse 0;
                for (adef.?.words[2..], 0..) |mt_id, mi| {
                    var mb: [32]u8 = undefined;
                    const mname = getMemberName(&module, actual_type, @intCast(mi), &mb);
                    const mtype = try wgslType(&module, mt_id, &names, arena);
                    const mflat = memberHasFlat(&module, actual_type, @intCast(mi)) or isIntegerWgslType(mtype);
                    try vertex_output_fields.append(arena, .{ .name = try arena.dupe(u8, mname), .type_name = mtype, .builtin = null, .location = base + @as(u32, @intCast(mi)), .flat = mflat });
                }
                continue;
            }
            // #170 (H): a matrix output cannot be a single @location member —
            // WGSL forbids it. Flatten matNxM into N consecutive vecM @location
            // members (one per column) and record the var so the Store site
            // writes each column. (Vertex-only: fragment outputs are vec4 colors.)
            if (builtin_val == null) {
                if (getDef(&module, actual_type)) |mdef| {
                    if (mdef.op == .TypeMatrix and mdef.words.len > 3) {
                        const cols = mdef.words[3];
                        const col_type = try wgslType(&module, mdef.words[2], &names, arena);
                        const base: u32 = loc_val orelse 0;
                        var c: u32 = 0;
                        while (c < cols) : (c += 1) {
                            const fname = try std.fmt.allocPrint(arena, "{s}_{d}", .{ var_name, c });
                            try vertex_output_fields.append(arena, .{ .name = fname, .type_name = col_type, .builtin = null, .location = base + c, .flat = false });
                        }
                        try matrix_outputs.put(ovid, .{ .base_name = try arena.dupe(u8, var_name), .cols = cols, .col_type = col_type });
                        continue;
                    }
                }
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
            // Integer varyings (or any GLSL `flat`-qualified one, lowered to a
            // SPIR-V Flat decoration) require @interpolate(flat); builtins are
            // not user-interpolated, so they never carry it.
            const needs_flat = bi_name == null and
                (hasDec(&decorations, ovid, .flat) or isIntegerWgslType(type_name));
            try vertex_output_fields.append(arena, .{ .name = var_name, .type_name = type_name, .builtin = bi_name, .location = loc_val, .flat = needs_flat });
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
            const interp: []const u8 = if (field.flat) "@interpolate(flat) " else "";
            if (field.builtin) |bi| {
                try w.print("    @builtin({s}) {s}: {s},\n", .{ bi, field.name, field.type_name });
            } else if (field.location) |loc| {
                auto_loc = loc + 1;
                try w.print("    @location({d}) {s}{s}: {s},\n", .{ loc, interp, field.name, field.type_name });
            } else {
                try w.print("    @location({d}) {s}{s}: {s},\n", .{ auto_loc, interp, field.name, field.type_name });
                auto_loc += 1;
            }
        }
        try w.writeAll("}\n\n");
    }

    // #170 (H): a deep-flattened output block is reassembled into a local of its
    // original (nested) struct type, so that struct (and its inner structs) must
    // be declared. The block was flattened away from VertexOutput, so nothing else
    // forces it — emit it here (deduped via emitted_structs). Inner structs first.
    {
        var ri = output_recons.iterator();
        while (ri.next()) |e| {
            const sty = e.value_ptr.struct_type;
            try emitStructForwardDecls(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
            try emitOneStructForwardDecl(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
        }
    }

    // Stage I/O interface blocks: a GLSL `in/out Block {…} inst;` lowers to a
    // struct-typed I/O variable. Declare it as a WGSL struct with @location /
    // @interpolate MEMBERS (passed by value) so member access `inst.f` works.
    // (A struct-typed I/O is ALWAYS an interface block here — non-block I/O is
    // scalar/vector — so this only affects the currently-naga-rejected cluster;
    // no passing shader has a struct I/O param.)
    var io_block_inputs = std.AutoHashMap(u32, void).init(arena);
    // #170 (H): stage-IO blocks whose members are THEMSELVES structs
    // (`in Block { Foo a; … }`) cannot put a struct at a single `@location`. Such
    // a block is emitted as a PLAIN struct (no @location) and its entry interface
    // becomes flattened leaf @location params, reassembled into a local var at
    // body start (see io_recons). This set holds those blocks' struct type ids.
    var nested_io_block_types = std.AutoHashMap(u32, void).init(arena);
    {
        var declared = std.AutoHashMap(u32, void).init(arena);
        for (input_vars.items) |iv| {
            // Same predicate as the redefinition pre-seed (ioBlockStructType): a
            // struct-typed stage input is ALWAYS a GLSL interface block (plain
            // structs cannot be non-block I/O), so the struct shape alone is the
            // signal — glslpp's SPIR-V does not emit the `Block` decoration.
            const sty = ioBlockStructType(&module, iv.type_id, iv.builtin) orelse continue;
            const sdef = getDef(&module, sty) orelse continue;
            try io_block_inputs.put(iv.id, {});
            if (blockHasAggregateMember(&module, sty)) try nested_io_block_types.put(sty, {});
            if (declared.contains(sty)) continue;
            try declared.put(sty, {});
            const sname = names.get(sty) orelse "Block";
            const base_loc = getDecVal(&decorations, iv.id, .location) orelse 0;
            if (nested_io_block_types.contains(sty)) {
                // Nested block → emit as a PLAIN struct (members keep their
                // original — possibly struct — types); the @location interface
                // lives on the flattened entry params, and the body uses the
                // reassembled local. First force-emit any inner member structs
                // (e.g. `Foo` in `Blk { Foo a; }`): nothing else references them
                // once the block is flattened off the entry signature, so they'd
                // be left undefined (naga: "no definition in scope for `Foo`").
                // emitOneStructForwardDecl emits the member structs but SKIPS the
                // block struct itself — it was pre-seeded into emitted_structs to
                // suppress the generic emitter — so we emit the block manually.
                try emitOneStructForwardDecl(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members);
                try w.print("struct {s} {{\n", .{sname});
                for (sdef.words[2..], 0..) |mt_id, mi| {
                    var mname_buf: [32]u8 = undefined;
                    const mname = getMemberName(&module, sty, @intCast(mi), &mname_buf);
                    const mtype = try wgslType(&module, mt_id, &names, arena);
                    try w.print("    {s}: {s},\n", .{ mname, mtype });
                }
                try w.writeAll("}\n\n");
                continue;
            }
            try w.print("struct {s} {{\n", .{sname});
            for (sdef.words[2..], 0..) |mt_id, mi| {
                var mname_buf: [32]u8 = undefined;
                const mname = getMemberName(&module, sty, @intCast(mi), &mname_buf);
                const mtype = try wgslType(&module, mt_id, &names, arena);
                const flat = memberHasFlat(&module, sty, @intCast(mi)) or isIntegerWgslType(mtype);
                const interp: []const u8 = if (flat) "@interpolate(flat) " else "";
                try w.print("    @location({d}) {s}{s}: {s},\n", .{ base_loc + @as(u32, @intCast(mi)), interp, mname, mtype });
            }
            try w.writeAll("}\n\n");
        }
    }
    // #170 (H): nested stage-IO blocks to reassemble from flattened params at body
    // start. Collected in the entry-param loop; emitted in the prologue (and each
    // block var renamed to its local so the body reads the reassembled struct).
    const IoRecon = struct { recon_name: []const u8, type_name: []const u8, ctor: []const u8 };
    var io_recons = std.ArrayList(IoRecon).initCapacity(arena, 2) catch return error.OutOfMemory;

    // Emit entry function
    const entry_stage: []const u8 = if (is_fragment) "@fragment" else if (is_vertex) "@vertex" else if (is_compute) "@compute" else "@fragment";

    if (is_compute) {
        const ls = module.local_size;
        try w.print("@compute @workgroup_size({d}, {d}, {d})\nfn main(", .{ls[0], ls[1], ls[2]});
    } else {
        try w.print("{s}\nfn main(", .{entry_stage});
    }

    // WGSL mandates `u32` for the vertex_index / instance_index built-ins, but
    // glslang types gl_VertexIndex / gl_InstanceIndex as signed i32 (which naga
    // rejects: "Built-in type for VertexIndex is invalid. Found Sint"). For each
    // such param we emit a `u32` parameter under a `_b` name and inject a
    // converting `let <name>: i32 = i32(<name>_b);` at the body start so signed
    // uses in the body stay valid. Collected here, emitted after the `{`.
    const BuiltinCoercion = struct { name: []const u8, src: []const u8 };
    var builtin_coercions = std.ArrayList(BuiltinCoercion).initCapacity(arena, 2) catch return error.OutOfMemory;
    // Promoted cross-function inputs: the entry parameter is renamed `<name>_in`
    // and the body copies it into the module-scope `var<private> <name>` global.
    const InputCopy = struct { global: []const u8, param: []const u8 };
    var input_copies = std.ArrayList(InputCopy).initCapacity(arena, 2) catch return error.OutOfMemory;

    // #170 (H): GLSL `layout(location=N, component=M)` packs several bindings
    // into one location's component slots. WGSL has no @component, so two stage
    // inputs sharing an explicit @location is invalid (naga: "Multiple bindings
    // at location N are present"). glslpp does not reconstruct component packing,
    // so fail loud rather than emit the naga-rejected duplicate-location
    // interface. (Builtins carry no @location; interface-block members carry
    // their own locations, so only plain @location varyings can collide here.)
    for (input_vars.items, 0..) |a, ai| {
        if (a.builtin != null or io_block_inputs.contains(a.id)) continue;
        const la = getDecVal(&decorations, a.id, .location) orelse continue;
        for (input_vars.items[ai + 1 ..]) |b| {
            if (b.builtin != null or io_block_inputs.contains(b.id)) continue;
            const lb = getDecVal(&decorations, b.id, .location) orelse continue;
            if (la == lb) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no @component: multiple inputs at @location({d}) (GLSL layout(component=…) packing) is not supported", .{la}) catch null;
                return error.UnsupportedOp;
            }
        }
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
            // Map the SPIR-V input built-in to its WGSL @builtin name. An unmapped
            // built-in (e.g. gl_PointCoord — no WGSL equivalent) must fail loud:
            // the old `else => "position"` fallback fabricated a bogus
            // @builtin(position) of the wrong type, which naga rejects (silent-wrong).
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
                .primitive_id => "primitive_id",
                .sample_id => "sample_index",
                else => {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no @builtin for input '{s}'", .{@tagName(bi)}) catch null;
                    return error.UnsupportedOp;
                },
            };
            const needs_u32 = switch (bi) {
                .vertex_id, .instance_id, .vertex_index, .instance_index => true,
                else => false,
            };
            if (needs_u32 and std.mem.eql(u8, type_name, "i32")) {
                const pname = try std.fmt.allocPrint(arena, "{s}_b", .{var_name});
                try w.print("@builtin({s}) {s}: u32", .{ builtin_name, pname });
                try builtin_coercions.append(arena, .{ .name = var_name, .src = pname });
            } else if (promoted_inputs.contains(iv.id)) {
                // Builtin read inside a helper: bridge the entry param `<name>_in`
                // → module-scope `var<private> <name>` (emitted above), copied at
                // body start, so helpers can reference the name in scope.
                const pname = try std.fmt.allocPrint(arena, "{s}_in", .{var_name});
                try w.print("@builtin({s}) {s}: {s}", .{ builtin_name, pname, type_name });
                try input_copies.append(arena, .{ .global = var_name, .param = pname });
            } else {
                try w.print("@builtin({s}) {s}: {s}", .{ builtin_name, var_name, type_name });
            }
        } else if (io_block_inputs.contains(iv.id)) {
            if (nested_io_block_types.contains(actual_type)) {
                // #170 (H): nested block — emit flattened leaf @location params and
                // queue a reassembly of the original (nested) struct into a local
                // `io_<name>` at body start. The block var is renamed to that local
                // so the body's nested accesses (`blk.a.b`) work unchanged. The
                // outer loop already wrote the leading ", " (when i>0), so the
                // first leaf emits no separator.
                const base_loc = getDecVal(&decorations, iv.id, .location) orelse 0;
                var loc: u32 = base_loc;
                var first_leaf = true;
                try emitFlattenedIoParams(&module, &names, actual_type, var_name, &loc, is_fragment, w, arena, &first_leaf);
                var ctor_buf = std.ArrayList(u8).initCapacity(arena, 64) catch return error.OutOfMemory;
                try buildIoReconExpr(&module, &names, actual_type, var_name, &ctor_buf, arena);
                // `names` values are freed with `alloc` at cleanup, so the renamed
                // value MUST be alloc-allocated (not arena). Free the displaced old.
                const recon_name = try std.fmt.allocPrint(alloc, "io_{s}", .{var_name});
                try io_recons.append(arena, .{ .recon_name = recon_name, .type_name = type_name, .ctor = try ctor_buf.toOwnedSlice(arena) });
                if (try names.fetchPut(iv.id, recon_name)) |old| alloc.free(old.value); // body now reads the local
            } else {
                // Interface-block input: a by-value struct parameter. Its MEMBERS
                // carry @location (emitted in the struct decl above); the parameter
                // itself must NOT have @location.
                try w.print("{s}: {s}", .{ var_name, type_name });
            }
        } else {
            const loc = getDecVal(&decorations, iv.id, .location) orelse i;
            // Fragment INPUTS that are integer-typed (or GLSL `flat`-qualified)
            // need @interpolate(flat). Vertex inputs are attributes (fetched, not
            // interpolated), so the attribute is illegal there — guard on stage.
            const interp: []const u8 = if (is_fragment and
                (hasDec(&decorations, iv.id, .flat) or isIntegerWgslType(type_name)))
                "@interpolate(flat) "
            else
                "";
            if (promoted_inputs.contains(iv.id)) {
                // Bridge: param `<name>_in` → module-scope `var<private> <name>`.
                const pname = try std.fmt.allocPrint(arena, "{s}_in", .{var_name});
                try w.print("@location({d}) {s}{s}: {s}", .{ loc, interp, pname, type_name });
                try input_copies.append(arena, .{ .global = var_name, .param = pname });
            } else {
                try w.print("@location({d}) {s}{s}: {s}", .{ loc, interp, var_name, type_name });
            }
        }
    }

    // Return type
    if (is_fragment and (use_frag_depth_struct or use_frag_mrt_struct)) {
        // The body returns `FragmentOutput(...)`, so the signature MUST declare
        // the return type — even for a depth-ONLY shader (no color output, so
        // output_var_id is null). Omitting it left `fn main()` returning a value
        // → naga "Returning Some where None is expected".
        try w.writeAll(") -> FragmentOutput {\n");
    } else if (is_fragment and output_vars.items.len > 0 and output_var_id != null) {
        {
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
                const interp: []const u8 = if (hasDec(&decorations, ov, .flat) or isIntegerWgslType(type_name))
                    "@interpolate(flat) "
                else
                    "";
                try w.print(") -> @location({d}) {s}{s} {{\n", .{ loc, interp, type_name });
            }
        } else {
            // Multiple outputs — emit struct return type
            try w.writeAll(") -> VertexOutput {\n");
            use_vertex_struct = true;
        }
    } else {
        try w.writeAll(") {\n");
    }

    // Inject u32→i32 conversions for vertex_index/instance_index built-ins so
    // the (signed) body references resolve while the parameter stays WGSL-legal.
    for (builtin_coercions.items) |c| {
        try w.print("    let {s}: i32 = i32({s});\n", .{ c.name, c.src });
    }
    // Copy promoted-input parameters into their module-scope var<private> globals
    // BEFORE any body statement reads them (var<private> is zero-initialised).
    for (input_copies.items) |c| {
        try w.print("    {s} = {s};\n", .{ c.global, c.param });
    }
    // #170 (H): reassemble each nested stage-IO block from its flattened leaf
    // params into a local of the original (nested) struct type, BEFORE any body
    // statement reads it. The block var was renamed to this local, so the body's
    // `blk.a.b` member accesses resolve against the real nested struct.
    for (io_recons.items) |r| {
        try w.print("    var {s}: {s} = {s};\n", .{ r.recon_name, r.type_name, r.ctor });
    }

    // Pre-scan: detect simple output variable pattern (single store before return)
    // If output var is stored to exactly once, we can return the value directly
    var direct_return_value: ?[]const u8 = null;
    var direct_return_id: ?u32 = null;
    var depth_return_value: ?[]const u8 = null;
    var depth_return_id: ?u32 = null;
    var mrt_return_values = std.ArrayList(struct { var_name: []const u8, value: []const u8, value_id: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    var skip_output_var_decl = false;
    // Whether any MRT output is READ BACK or PARTIALLY written (e.g. `vo0.x += …`,
    // which lowers to an OpAccessChain rooted at the output). The simple MRT path
    // assumes each output is whole-var-stored exactly once and never read, builds
    // the return from those captured store values, and declares no `var`. That
    // breaks a read/partial-write output two ways: the access-chain reference is
    // undeclared (naga reject) AND the increment is silently dropped from the
    // return. When this is set we instead declare real local `var`s, emit every
    // store normally, and return the locals — see below.
    var mrt_is_read = false;
    if (!use_vertex_struct and output_var_id != null) {
        const ov = output_var_id.?;
        var store_count: usize = 0;
        var last_stored_value: ?[]const u8 = null;
        var last_stored_id: ?u32 = null;
        // Whether the output variable is READ back (loaded or access-chained) in
        // the body. The direct-return optimization replaces the output var with a
        // returned value and skips declaring it — but if the body reads the output
        // (e.g. partial writes `result.xy=…; result.zw=…` with a `result.z` read,
        // or any load of the output), those references would be undefined. In that
        // case we must declare it as a local `var` (zero-initialised) and return
        // it normally rather than direct-return.
        var output_is_read = false;
        // Scan function body for stores to the output variable
        var sci: usize = entry_func_idx.? + 1;
        while (sci < module.instructions.len) : (sci += 1) {
            const si = module.instructions[sci];
            if (si.op == .FunctionEnd) break;
            if ((si.op == .Load or si.op == .AccessChain or si.op == .CopyObject) and si.words.len > 3 and si.words[3] == ov) {
                output_is_read = true;
            }
            if (si.op == .Store and si.words.len >= 3 and si.words[1] == ov) {
                store_count += 1;
                last_stored_value = names.get(si.words[2]);
                last_stored_id = si.words[2];
            }
            // Track depth output stores
            if (depth_output_var_id != null and si.op == .Store and si.words.len >= 3 and si.words[1] == depth_output_var_id.?) {
                depth_return_value = names.get(si.words[2]);
                depth_return_id = si.words[2];
            }
            // Track MRT output stores
            if (use_frag_mrt_struct and si.op == .Store and si.words.len >= 3) {
                for (output_vars.items) |ovid| {
                    if (si.words[1] == ovid) {
                        const vn = names.get(ovid) orelse continue;
                        const val = names.get(si.words[2]) orelse continue;
                        try mrt_return_values.append(arena, .{ .var_name = vn, .value = val, .value_id = si.words[2] });
                    }
                }
            }
            // Detect an MRT output read back or partially written (access-chain
            // rooted at the output, e.g. `vo0.x`): triggers the real-local-var path.
            if (use_frag_mrt_struct and (si.op == .Load or si.op == .AccessChain or si.op == .CopyObject) and si.words.len > 3) {
                for (output_vars.items) |ovid| {
                    if (si.words[3] == ovid) mrt_is_read = true;
                }
            }
        }
        if (store_count == 1 and last_stored_value != null and !output_is_read) {
            // Dupe into the arena: `last_stored_value` aliases an entry in the
            // mutable `names` map, which a later rewrite (fetchPut frees the old
            // value) can invalidate — leaving direct_return_value dangling (it
            // surfaced as `return \xAA\xAA`, freed-memory fill, for `o = -(-x)`).
            direct_return_value = arena.dupe(u8, last_stored_value.?) catch last_stored_value.?;
            direct_return_id = last_stored_id;
            skip_output_var_decl = true;
        }
        // MRT: simple case (each output whole-var-stored once, never read) skips
        // the local decl and returns the captured store values. If any output is
        // read/partially written, keep the locals (declared below) and emit stores.
        if (use_frag_mrt_struct and !mrt_is_read) {
            skip_output_var_decl = true;
        }
        // Promoted cross-function output: declared as a module-scope var<private>
        // above, so suppress the entry-local `var` decl (the `return <name>` at
        // the end resolves to the global).
        if (promoted_outputs.contains(ov)) {
            skip_output_var_decl = true;
        }
    }

    // Declare output variable(s) as local (skip if direct return)
    if (!skip_output_var_decl) {
        if (use_frag_mrt_struct and mrt_is_read) {
            // Complex MRT: declare every color output as a real local `var` so the
            // body's stores AND access-chain read/partial-writes resolve; the
            // return builds FragmentOutput from these locals (below).
            for (output_vars.items) |ovid| {
                const var_inst = getDef(&module, ovid) orelse continue;
                var actual_type: u32 = var_inst.words[1];
                if (getDef(&module, actual_type)) |pi| {
                    if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
                }
                const type_name = try wgslType(&module, actual_type, &names, arena);
                const var_name = names.get(ovid) orelse continue;
                try w.print("    var {s}: {s};\n", .{ var_name, type_name });
            }
        } else if (use_vertex_struct) {
            try w.writeAll("    var vertex_out: VertexOutput;\n");
            // #170 (H): declare the reassembly local for each deep-flattened output
            // block; the body writes it (`io_foo.a[i] = …`) and the leaves are
            // copied into vertex_out before return.
            {
                var ri = output_recons.iterator();
                while (ri.next()) |e| {
                    try w.print("    var {s}: {s};\n", .{ e.value_ptr.local_name, e.value_ptr.type_name });
                }
            }
            for (output_vars.items) |ovid| {
                const var_name = names.get(ovid) orelse continue;
                // A flattened output block aliases to `vertex_out` itself, so the
                // body's `vout.member` access chain resolves to `vertex_out.member`
                // (the flattened field) rather than the (nonexistent) nested field.
                // A deep-flattened block instead aliases to its reassembly local so
                // `vout.member[i]` resolves against the real nested struct.
                const alias = if (output_recons.get(ovid)) |rec|
                    try alloc.dupe(u8, rec.local_name)
                else if (io_block_outputs.contains(ovid))
                    try std.fmt.allocPrint(alloc, "vertex_out", .{})
                else
                    try std.fmt.allocPrint(alloc, "vertex_out.{s}", .{var_name});
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

    // Build MRT skip set for stores. Only in the simple case — when an output is
    // read/partially written we MUST let its stores emit (to the local `var`),
    // otherwise the increment is dropped (silent-wrong).
    var mrt_skip_set = std.AutoHashMap(u32, void).init(arena);
    if (use_frag_mrt_struct and !mrt_is_read) {
        for (output_vars.items) |ovid| {
            try mrt_skip_set.put(ovid, {});
        }
    }

    // Determine how a mid-body EARLY return assembles the entry output. The
    // trailing return (emitted after emitBody, below) collapses all paths into a
    // single exit; an early return must reproduce that exit at its own point.
    // Only the cases whose trailing return is a single named local (returned
    // verbatim) can be reproduced cleanly — the rest are assembled from
    // end-captured values and must fail loud (see EarlyReturnMode).
    const early_return_mode: EarlyReturnMode = blk: {
        if (use_frag_depth_struct or use_frag_mrt_struct) break :blk .honest_error;
        if (use_vertex_struct) {
            // Deep-flattened outputs are copied into vertex_out only at the
            // trailing return (output_copyouts); an early `return vertex_out;`
            // would miss those, so honest-error. The common case (no recons)
            // writes every output — including matrix-output columns
            // (`vertex_out.{base}_{c}`) — directly into vertex_out members, so an
            // early return captures exactly what was written so far. Return as-is.
            break :blk if (output_recons.count() == 0) .{ .stmt = "return vertex_out;" } else .honest_error;
        }
        // Single-store direct return: the output is never declared as a `var`;
        // the value is captured and returned at the end. An early return has no
        // local to assemble from.
        if (direct_return_id != null) break :blk .honest_error;
        if ((is_fragment or is_vertex) and output_var_id != null) {
            const nm = names.get(output_var_id.?) orelse break :blk .honest_error;
            break :blk .{ .stmt = try std.fmt.allocPrint(arena, "return {s};", .{nm}) };
        }
        // No returned value (compute, or an output-less stage): a plain `return;`
        // is valid WGSL.
        break :blk .{ .stmt = "return;" };
    };

    // Emit function body
    try emitBody(&module, &names, &decorations, entry_func_idx.?, w, alloc, arena, null, if (skip_output_var_decl) output_var_id else null, if (mrt_skip_set.count() > 0) &mrt_skip_set else null, &wrapped_uniform_arrays, &wrapped_uniform_members, &matrix_outputs, &atomic_vars, early_return_mode);

    // Re-resolve the direct-return value AFTER emitBody: a passthrough store
    // (`o = x`, or `o = -(-x)` after double-negate folding) feeds an OpLoad
    // whose result emitBody inlines to the *source* name (e.g. `vIn`) and never
    // emits as a `let`. The name captured pre-emitBody (`v6`) is therefore
    // undefined in the output; re-reading names[id] now yields the inlined name.
    if (direct_return_id) |drid| {
        if (names.get(drid)) |nm| direct_return_value = arena.dupe(u8, nm) catch nm;
    }
    // Same passthrough hazard for the depth and MRT return paths.
    if (depth_return_id) |drid| {
        if (names.get(drid)) |nm| depth_return_value = arena.dupe(u8, nm) catch nm;
    }
    for (mrt_return_values.items) |*rv| {
        if (names.get(rv.value_id)) |nm| rv.value = arena.dupe(u8, nm) catch nm;
    }

    // Return output var
    if (use_frag_depth_struct) {
        const color_val = direct_return_value orelse (if (output_var_id != null) names.get(output_var_id.?) orelse "vec4f()" else "vec4f()");
        const depth_val = depth_return_value orelse "0.0";
        try w.print("    return FragmentOutput({s}, {s});\n", .{ color_val, depth_val });
    } else if (use_frag_mrt_struct) {
        // Build FragmentOutput. Complex case (any output read/partially written):
        // the outputs are real local `var`s holding their final values, so return
        // them BY NAME (preserves `vo0.x += …` increments). Simple case: use the
        // captured whole-var store values.
        var mrt_parts = std.ArrayList(u8).initCapacity(arena, 256) catch return error.OutOfMemory;
        for (output_vars.items) |ovid| {
            const vn = names.get(ovid) orelse continue;
            if (mrt_parts.items.len > 0) try mrt_parts.appendSlice(arena, ", ");
            if (mrt_is_read) {
                try mrt_parts.appendSlice(arena, vn);
            } else {
                // Find the last stored value for this output var
                var stored_val: ?[]const u8 = null;
                for (mrt_return_values.items) |rv| {
                    if (std.mem.eql(u8, rv.var_name, vn)) stored_val = rv.value;
                }
                try mrt_parts.appendSlice(arena, stored_val orelse "vec4f()");
            }
        }
        try w.print("    return FragmentOutput({s});\n", .{mrt_parts.items});
    } else if (use_vertex_struct) {
        // #170 (H): copy each deep-flattened output leaf out of its reassembly
        // local into the flattened VertexOutput member, just before returning.
        for (output_copyouts.items) |co| {
            try w.print("    vertex_out.{s} = {s};\n", .{ co.flat, co.src });
        }
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
                    // A member/swizzle write (`v.z = …`, `m._0 = …`) mutates the BASE
                    // variable, so register the identifier up to the first `.`/`[` —
                    // NOT the full `v.z` (which would leave `v` looking immutable and
                    // get it wrongly promoted to `let`, then illegally member-assigned).
                    const base = potential_name[0 .. std.mem.indexOfAny(u8, potential_name, ".[") orelse potential_name.len];
                    const name_copy = try arena.dupe(u8, base);
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

fn emitBody(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), func_idx: usize, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, inout_return: ?[]const u8, skip_store_target: ?u32, skip_store_targets: ?*const std.AutoHashMap(u32, void), wrapped_uniform_arrays: *const std.AutoHashMap(u32, void), wrapped_members: *const WrappedUniformMemberMap, matrix_outputs: *const std.AutoHashMap(u32, MatrixOutput), atomic_vars: *const std.AutoHashMap(u32, void), early_return: EarlyReturnMode) !void {
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

    // Index of the function's LAST OpReturn — the terminator of the final block,
    // which the wrapper turns into the trailing output-struct return. Any earlier
    // OpReturn (or one nested in a selection/loop) is an EARLY return that must
    // actually exit; see the `.Return` arm.
    var last_return_idx: usize = 0;
    {
        var ri: usize = func_idx + 1;
        while (ri < module.instructions.len) : (ri += 1) {
            const rinst = module.instructions[ri];
            if (rinst.op == .FunctionEnd) break;
            if (rinst.op == .Return or rinst.op == .ReturnValue) last_return_idx = ri;
        }
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
    // Track phi range for pending loop (Phi processed before LoopMerge).
    // `phi_group_open` is set at the FIRST loop-header phi of a loop and cleared
    // at that loop's LoopMerge. This makes multi-phi loop headers include ALL
    // their phis (not just the last), and — crucially — gives loops with NO phis
    // an EMPTY range instead of inheriting the previous loop's trailing phi
    // update (which leaked e.g. `j = j+4` into unrelated later loops, referencing
    // an out-of-scope `vN` that naga rejects).
    var pending_phi_start: usize = 0;
    var phi_group_open: bool = false;

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

    // Pre-pass (MUST run before the AccessChain pre-scan below): propagate the
    // source name of DIRECT-variable loads (e.g. `%27 = OpLoad %int %index`, or
    // `OpLoad %float %FragColor`) onto the load result. The AccessChain pre-scan
    // and the arithmetic inline-expression pre-scan freeze operands by name; the
    // load-name propagation, however, used to happen ONLY at emission time (the
    // is_input/is_output/is_tex branches plus the generic immutable-load loop),
    // which runs AFTER those pre-scans. So a reloaded input/output value resolved
    // to its raw default `vN` inside a frozen inline expression while direct
    // emission used the real name (`index`, `FragColor`) — the same value under
    // two names, leaving the `vN` undeclared (naga "no definition in scope",
    // silent-wrong). Doing it here keeps every emission path consistent.
    //
    // Output/Input/texture loads propagate the variable name UNCONDITIONALLY
    // (mirroring emission), since in WGSL those are read by name at the use site.
    // Other variables (Uniform/PushConstant/Private/Function) propagate only when
    // the pointer is not a Store target, so mutable values still capture per-load.
    // Loads of AccessChain results are left to the value-name loop after the
    // pre-scan, since their names depend on the expressions it builds.
    {
        var it = def_op.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .Load and entry.value_ptr.* != .CopyObject) continue;
            const result_id = entry.key_ptr.*;
            const load_inst = getDef(module, result_id) orelse continue;
            if (load_inst.words.len <= 3) continue;
            const ptr_id = load_inst.words[3];
            const ptr_def = getDef(module, ptr_id) orelse continue;
            if (ptr_def.op != .Variable or ptr_def.words.len < 4) continue; // direct-variable loads only
            const sc: spirv.StorageClass = @enumFromInt(ptr_def.words[3]);
            // Texture/sampler loads (UniformConstant whose element is an image/
            // sampler/sampled-image) propagate unconditionally, like is_tex.
            var is_tex = false;
            if (sc == .UniformConstant) {
                if (getDef(module, ptr_def.words[1])) |ptv| {
                    if (ptv.op == .TypePointer and ptv.words.len > 3) {
                        if (getDef(module, ptv.words[3])) |pev| {
                            is_tex = (pev.op == .TypeSampler or pev.op == .TypeSampledImage or pev.op == .TypeImage);
                        }
                    }
                }
            }
            const unconditional = (sc == .Output or sc == .Input or is_tex);
            // Mutable, non-special variables must capture the current value.
            if (!unconditional and store_targets.contains(ptr_id)) continue;
            const ptr_name = names.get(ptr_id) orelse continue;
            if (ptr_name.len == 0) continue;
            const current_name = names.get(result_id) orelse "";
            if (std.mem.eql(u8, ptr_name, current_name)) continue; // already aligned
            const name_copy = try alloc.dupe(u8, ptr_name);
            if (try names.fetchPut(result_id, name_copy)) |old| alloc.free(old.value);
            try inline_loads.put(result_id, {});
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
                var expr = buildAccessExpr(module, names, base_id, ac_inst.words[4..], alloc, wrapped_members) catch continue;
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

    // For single-use OpLoad results, inline the source pointer name (continued).
    // `inline_loads` and `store_targets` were set up before the AccessChain
    // pre-scan above (so direct immutable-variable loads are named first). This
    // loop covers the remaining loads — notably loads of AccessChain results,
    // whose names depend on the expressions that pre-scan built.
    {
        var it = def_op.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .Load or entry.value_ptr.* == .CopyObject) {
                const result_id = entry.key_ptr.*;
                // Already handled by the direct-variable pre-pass — its name and
                // inline status are final; re-running would self-assignment-rename it.
                if (inline_loads.contains(result_id)) continue;
                // Immutable loads (pointers that are NOT store targets — inputs,
                // uniforms, push-constants, spec-consts) are inlined to the source
                // name at ANY use count: the value can't change, so substitution is
                // value-equivalent. A prior `uses <= 6` cap left heavily-used loads
                // (e.g. an input read in many branches) neither inlined NOR emitted
                // as a `let`, so inline expressions referenced an undefined `vN`
                // (naga-rejected silent-wrong). Store-target loads are still skipped
                // below to preserve load-before-store semantics.
                {
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
            // Leave OpIAddCarry/OpISubBorrow member extracts alone — their struct
            // result is never emitted, so inlining would rename them to
            // `<unemitted-result>.<member>` (an undefined identifier). They are
            // recomputed from the operands in the CompositeExtract arm. (#170)
            if (getDef(module, scan_inst.words[3])) |src_def| {
                if (isAddCarryOrSubBorrow(src_def.op)) continue;
            }
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
                var is_array_elem = false;
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
                        // An ARRAY element is indexed `[idx]`, NOT swizzled. Without
                        // this, `arr[0]` (extract index 0 from `array<vec4,2>`) was
                        // inlined as `arr.x` — a vector swizzle on an array, which
                        // naga rejects ("invalid field accessor `x`"). Silent-wrong.
                        if (sd2.op == .TypeArray or sd2.op == .TypeRuntimeArray) {
                            is_array_elem = true;
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
                } else if (is_matrix_col or is_array_elem) {
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
                // Only a VECTOR source has a swizzle form to collapse into. A struct
                // source (e.g. the {result,carry} struct of OpIAddCarry/OpISubBorrow)
                // must NOT have its member extracts marked dead here — the emit path's
                // matching `src_is_struct` guard keeps them as separate args, so
                // dropping them would leave those args referencing undefined names. (#170)
                var src_is_struct = false;
                if (lead_source) |ls| {
                    if (resolveTypeOf(module, ls)) |st| {
                        if (getDef(module, st)) |sd2| {
                            if (sd2.op == .TypeStruct) src_is_struct = true;
                        }
                    }
                }
                if (lead_count >= 2 and lead_source != null and !src_is_struct) {
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
                                        try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, body_ind, wrapped_members, matrix_outputs);
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
                                        try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, body_ind, wrapped_members, matrix_outputs);
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
                    // A loop with no header phis must get an EMPTY range, not the
                    // stale `pending_phi_start` from a previous loop.
                    const phi_start = if (phi_group_open) pending_phi_start else phi_updates.items.len;
                    const phi_end = phi_updates.items.len;
                    phi_group_open = false;
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
                                    try emitSimpleInstruction(module, names, &inline_exprs, dinst, w, alloc, arena, indent, wrapped_members, matrix_outputs);
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
                    // If a LoopMerge follows, this phi is a LOOP-HEADER phi.
                    var lm_follows = false;
                    {
                        var pk = i + 1;
                        while (pk < @min(i + 20, module.instructions.len)) : (pk += 1) {
                            if (module.instructions[pk].op == .LoopMerge) { lm_follows = true; break; }
                            if (module.instructions[pk].op == .FunctionEnd or module.instructions[pk].op == .Label) break;
                        }
                    }
                    // Classify the phi's incoming (value, label) pairs. SPIR-V does
                    // NOT fix their order, so a loop-header phi's pairs may be either
                    // (preheader, back-edge) or (back-edge, preheader). Pick the
                    // PREHEADER pair (its label's OpLabel is defined BEFORE this
                    // header block, index < i) as the `var` initializer, and the
                    // BACK-EDGE pair (label defined AFTER, inside the loop body) as
                    // the continue-block update. The old code hardcoded words[3]=init
                    // / words[5]=update; when glslang emitted the pairs reversed, the
                    // loop var was initialized from the not-yet-defined increment →
                    // naga "no definition in scope for identifier: vN". Non-loop
                    // (selection-merge) phis are handled elsewhere; here we keep the
                    // positional default unless we positively identify the preheader.
                    var init_value_id = inst.words[3];
                    var update_value_id = inst.words[5];
                    if (lm_follows) {
                        var pp: usize = 3;
                        while (pp + 1 < inst.words.len) : (pp += 2) {
                            const val_id = inst.words[pp];
                            const lbl_id = inst.words[pp + 1];
                            var lbl_idx: ?usize = null;
                            for (module.instructions, 0..) |li, lii| {
                                if (li.op == .Label and li.words.len > 1 and li.words[1] == lbl_id) {
                                    lbl_idx = lii;
                                    break;
                                }
                            }
                            if (lbl_idx) |lx| {
                                if (lx < i) init_value_id = val_id else update_value_id = val_id;
                            }
                        }
                    }
                    if (!already_declared) {
                        const phi_type = try wgslType(module, inst.words[1], names, arena);
                        const init_val = names.get(init_value_id) orelse "0";
                        try writeInd(w, indent); try w.print("var {s}: {s} = {s};\n", .{ phi_result.?, phi_type, init_val });
                    }
                    if (lm_follows and !phi_group_open) {
                        // First loop-header phi of this loop: open the group once so
                        // ALL of the header's phis are captured (set BEFORE adding).
                        pending_phi_start = phi_updates.items.len;
                        phi_group_open = true;
                    }
                    if (inst.words.len >= 7) {
                        phi_updates.appendAssumeCapacity(.{ .result_id = inst.words[2], .value_id = update_value_id });
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
                                                    try emitSimpleInstruction(module, names, &inline_exprs, cbinst, w, alloc, arena, indent + 1, wrapped_members, matrix_outputs);
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
                                                    try emitSimpleInstruction(module, names, &inline_exprs, cbinst, w, alloc, arena, indent + 1, wrapped_members, matrix_outputs);
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

                    // Non-phi loop header: this block declares an OpLoopMerge but
                    // carries no header Phi (a `while`/`do` loop whose loop-carried
                    // values stayed memory vars). Its computations (e.g. the
                    // OpLoad of a condition variable, reused in the body) must be
                    // emitted INSIDE the loop so they re-evaluate each iteration —
                    // otherwise they are hoisted before `loop {` and the body reads
                    // a stale pre-loop snapshot. Defer them via the same machinery
                    // the Phi path uses; the LoopMerge arm replays them in-body.
                    // (Phi loops are already deferred by the Phi handler.)
                    if (!defer_active) {
                        var k: usize = i + 1;
                        var has_phi = false;
                        var is_loop_header = false;
                        while (k < module.instructions.len) : (k += 1) {
                            switch (module.instructions[k].op) {
                                .Phi => has_phi = true,
                                .LoopMerge => { is_loop_header = true; break; },
                                .Label, .Branch, .BranchConditional, .Switch, .SelectionMerge, .Return, .ReturnValue, .Kill, .Unreachable, .FunctionEnd => break,
                                else => {},
                            }
                        }
                        if (is_loop_header and !has_phi) {
                            defer_active = true;
                            defer_start = i + 1;
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
                // #170 (F): a plain load of a `shared` atomic scalar lowers to
                // atomicLoad. Materialize as a `let` (one atomic read) so a
                // multi-use value isn't re-read per use. The result id is already
                // named (result_name), so downstream uses resolve to it.
                if (atomic_vars.contains(inst.words[3])) {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = atomicLoad(&{s});\n", .{ result_name, rt, ptr });
                    continue;
                }
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
                            const fresh_expr_opt: ?[]const u8 = buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc, wrapped_members) catch null;
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
                            expr = try buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc, wrapped_members);
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
                // #170 (H): a whole-matrix store to a flattened matrix output var
                // becomes per-column writes into the vecN @location members
                // (`vertex_out.{base}_{c} = ({val})[{c}]`). The matrix value is
                // wrapped in parens so an inlined access-chain expression indexes
                // correctly. (Matrix values are pure, so per-column re-reference is
                // value-safe.)
                if (matrix_outputs.get(inst.words[1])) |mo| {
                    const mval = names.get(inst.words[2]) orelse "mat4x4f()";
                    var c: u32 = 0;
                    while (c < mo.cols) : (c += 1) {
                        try writeInd(w, indent);
                        try w.print("vertex_out.{s}_{d} = ({s})[{d}];\n", .{ mo.base_name, c, mval, c });
                    }
                    continue;
                }
                // #170 (F): a plain store to a `shared` atomic scalar lowers to
                // atomicStore (the var is declared `atomic<T>`, so `s = x;` is
                // naga-invalid).
                if (atomic_vars.contains(inst.words[1])) {
                    const aval = names.get(inst.words[2]) orelse "0";
                    const aptr = names.get(inst.words[1]) orelse "v";
                    try writeInd(w, indent);
                    try w.print("atomicStore(&{s}, {s});\n", .{ aptr, aval });
                    continue;
                }
                // #170 (H): a PARTIAL write to one column of a flattened matrix
                // output (`M[c] = col;`) targets an AccessChain into the matrix
                // var — its flattened `{base}_{c}` members can't be addressed that
                // way, so emitting `vertex_out.M[c]` is naga-invalid (no member
                // `M`). Out of corpus; fail loud rather than emit invalid WGSL.
                if (getDef(module, inst.words[1])) |ti| {
                    if (ti.op == .AccessChain and ti.words.len > 3 and matrix_outputs.contains(ti.words[3])) {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL matrix-output flattening does not support partial column writes (matrix out[c] = …)", .{}) catch null;
                        return error.UnsupportedOp;
                    }
                }
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
                        expr = try buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc, wrapped_members);
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
                const expr = try buildAccessExpr(module, names, base_id, inst.words[4..], alloc, wrapped_members);
                if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
            },

            // CompositeConstruct
            .CompositeConstruct => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const num_comps = inst.words.len - 3;
                // A STRUCT result needs one argument per field — the vector
                // simplifications below (broadcast `T(x)`, sequential-extract
                // collapse `T(v)` / `T(v.xy)`) are only valid for vector results.
                // `Point(uv.x, uv.y)` collapsed to `Point(uv)` (passing a vec2 to a
                // 2-scalar struct) — naga-invalid. Force the per-field general case.
                const is_struct_result = isStructType(module, inst.words[1]);
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
                if (!is_struct_result and all_same and num_comps > 1 and first_comp != null) {
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
                    if (lead_count >= 2 and lead_source != null and !src_is_struct and !is_struct_result) {
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
                // OpIAddCarry/OpISubBorrow extract: the struct result has no WGSL
                // value (see the no-op arm). Recompute the requested member straight
                // from the operands. Member 0 is the wrapping add/sub (WGSL unsigned
                // arithmetic wraps, matching SPIR-V); member 1 is the carry/borrow
                // flag, 1 exactly where the unsigned op over/under-flowed:
                //   carry  = (x + y) < x   (the sum wrapped below an addend)
                //   borrow = x < y         (the minuend is smaller than the subtrahend)
                // `select`/`<` are componentwise, so scalar and vector forms share
                // one path. Single-index extract only (these structs are flat). (#170)
                if (inst.words.len == 5) {
                    if (getDef(module, inst.words[3])) |sd| {
                        if (isAddCarryOrSubBorrow(sd.op) and sd.words.len >= 5) {
                            const x = names.get(sd.words[3]) orelse "0u";
                            const y = names.get(sd.words[4]) orelse "0u";
                            try writeInd(w, indent);
                            if (inst.words[4] == 0) {
                                const op_str: []const u8 = if (isAddCarry(sd.op)) "+" else "-";
                                try w.print("let {s}: {s} = ({s} {s} {s});\n", .{ result_name, rt, x, op_str, y });
                            } else {
                                const cond = if (isAddCarry(sd.op))
                                    try std.fmt.allocPrint(arena, "({s} + {s}) < {s}", .{ x, y, x })
                                else
                                    try std.fmt.allocPrint(arena, "{s} < {s}", .{ x, y });
                                try w.print("let {s}: {s} = select({s}(0u), {s}(1u), {s});\n", .{ result_name, rt, rt, rt, cond });
                            }
                            continue;
                        }
                    }
                }
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
                // WGSL requires the shift AMOUNT to be u32-typed with the SAME
                // vector dimension as the base: `vecN<T> << vecN<u32>` (a scalar
                // `u32(...)` on a vec2 amount is rejected — "cannot cast a
                // vec2<u32> to a u32"). Derive the coercion type from the result
                // (= base) type.
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const lhs_raw = resolveOperandExpr(module, names, &inline_exprs, inst.words[3], arena, 0);
                const rhs_raw = resolveOperandExpr(module, names, &inline_exprs, inst.words[4], arena, 0);
                const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
                const op_str: []const u8 = if (inst.op == .ShiftLeftLogical) "<<" else ">>";
                const shift_cast: []const u8 = if (std.mem.startsWith(u8, rt, "vec2")) "vec2<u32>" else if (std.mem.startsWith(u8, rt, "vec3")) "vec3<u32>" else if (std.mem.startsWith(u8, rt, "vec4")) "vec4<u32>" else "u32";
                try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s} {s} {s}({s});\n", .{ result_name, rt, lhs, op_str, shift_cast, rhs_raw });
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

            // OuterProduct(u, v): u is the result's column vector type (R rows),
            // v supplies the columns (C components). The result is a CxR matrix
            // whose column i is `u * v[i]`. WGSL has no outerProduct builtin —
            // construct the matrix explicitly (matCxR(u*v.x, u*v.y, ...)).
            .OuterProduct => try emitOuterProduct(module, names, inst, w, arena, indent),

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
            // Boolean equality (GLSL bool `==`/`!=`, `equal`/`notEqual` on bvecN).
            // WGSL `==`/`!=` apply to bool and are componentwise on vecN<bool>. (#170)
            .LogicalEqual => try emitBinOp(module, names, &inline_exprs, inst, "==", w, arena, indent),
            .LogicalNotEqual => try emitBinOp(module, names, &inline_exprs, inst, "!=", w, arena, indent),
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
                const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
                // Arrayed (non-depth) textures take the layer as a SEPARATE i32 arg:
                // textureSample(t, s, coord.xy, i32(round(coord.z))). The layer is
                // ROUNDED (floor(layer+0.5)) for glslang parity — mirrors the depth-
                // array path in emitDepthCompare and the MSL rint() lowering.
                const shape = arrayedSampleShape(module, inst.words[3]);
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureSample({s}, {s}, {s}{s}, i32(round({s}{s})));\n", .{ result_name, rt, tex_name, sampler_arg, coord, cs, coord, ls });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureSample({s}, {s}, {s});\n", .{ result_name, rt, tex_name, sampler_arg, coord });
                }
            },

            .ImageSampleExplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
                // Arrayed: textureSampleLevel(t, s, coord.xy, i32(round(coord.z)), lod).
                // Layer rounded for glslang parity (see ImageSampleImplicitLod).
                const shape = arrayedSampleShape(module, inst.words[3]);
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureSampleLevel({s}, {s}, {s}{s}, i32(round({s}{s})), {s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, cs, coord, ls, lod });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureSampleLevel({s}, {s}, {s}, {s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, lod });
                }
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
                // WGSL textureLoad on a SAMPLED or MULTISAMPLED texture REQUIRES a
                // 3rd argument — the mip level (sampled) or the sample index (MS).
                // GLSL texelFetch always carries it as an OpImageFetch image operand
                // (Lod/Sample) at words[6] (words[5] = operand mask). Emitting only
                // (t, coord) produced WGSL naga rejects. (Storage-image loads go
                // through OpImageRead, which correctly takes 2 args.)
                // Arrayed textures take the layer as a SEPARATE i32 arg before the
                // level: textureLoad(t, coord.xy, i32(coord.z), level). The fetch
                // coordinate is already integer, so the layer needs no rounding.
                const shape = arrayedSampleShape(module, inst.words[3]);
                const cs = if (shape.arrayed) arrayedCoordSwizzle(shape.comps) else "";
                const layer_arg: []const u8 = if (shape.arrayed)
                    try std.fmt.allocPrint(arena, "i32({s}{s}), ", .{ coord, arrayedLayerSwizzle(shape.comps) })
                else
                    "";
                if (inst.words.len > 6) {
                    const level_or_sample = names.get(inst.words[6]) orelse "0";
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureLoad({s}, {s}{s}, {s}{s});\n", .{ result_name, rt, si, coord, cs, layer_arg, level_or_sample });
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureLoad({s}, {s}{s}, {s}0);\n", .{ result_name, rt, si, coord, cs, layer_arg });
                }
            },

            // Return
            .Return => {
                if (inout_return) |ret_name| {
                    try writeInd(w, indent); try w.print("return {s};\n", .{ret_name});
                } else {
                    // Entry function. The FINAL return (terminator of the last
                    // block, at top level) is collapsed into the wrapper's trailing
                    // output-struct return, so it is dropped here. A mid-body EARLY
                    // return — nested in a selection/loop, or textually before the
                    // final return — must actually exit, or later stage-IO writes
                    // overwrite the branch's output (silent-wrong).
                    const is_early = i != last_return_idx or if_depth > 0 or in_loop;
                    if (is_early) {
                        switch (early_return) {
                            .none => {},
                            .stmt => |s| {
                                try writeInd(w, indent); try w.print("{s}\n", .{s});
                            },
                            .honest_error => return recordUnsupportedEarlyReturn(),
                        }
                    }
                }
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
                        // GLSL.std.450 Frexp (51) / Modf (35) are POINTER-form: the
                        // result is the significand/fractional part and the 2nd
                        // operand is an out-pointer for the exponent/integer part.
                        // WGSL has no pointer form — frexp(x)/modf(x) RETURN a struct
                        // ({fract, exp} / {fract, whole}). Emit a temp, then bind the
                        // result to `.fract` and the out-pointer's variable to the
                        // second field. (Emitting the old `frexp(x, ptr)` was a naga
                        // reject — "too many arguments" — and dropped the exponent.)
                        if (instruction == 34) {
                            // MatrixInverse → generated spvInverseN helper (WGSL
                            // has no inverse builtin). The pre-emit scan flagged
                            // the size; a non-square / unsupported size has no
                            // inverse → honest-error.
                            const dim = inverseMatrixDim(module, inst.words[1]) orelse {
                                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL inverse() unsupported for this matrix (only square mat2/mat3/mat4)", .{}) catch null;
                                return error.UnsupportedExtInst;
                            };
                            const m = names.get(inst.words[5]) orelse "m";
                            try writeInd(w, indent); try w.print("let {s}: {s} = spvInverse{d}({s});\n", .{ result_name, rt, dim, m });
                        } else if (instruction == 51 or instruction == 35) {
                            const x = names.get(inst.words[5]) orelse "0";
                            const builtin = if (instruction == 51) "frexp" else "modf";
                            const second_field = if (instruction == 51) "exp" else "whole";
                            const tmp = std.fmt.allocPrint(arena, "{s}_sm", .{result_name}) catch "_sm";
                            try writeInd(w, indent); try w.print("let {s} = {s}({s});\n", .{ tmp, builtin, x });
                            if (inst.words.len > 6) {
                                if (names.get(inst.words[6])) |ptr_name| {
                                    try writeInd(w, indent); try w.print("{s} = {s}.{s};\n", .{ ptr_name, tmp, second_field });
                                }
                            }
                            try writeInd(w, indent); try w.print("let {s}: {s} = {s}.fract;\n", .{ result_name, rt, tmp });
                        } else if (scalarGeomLower(arena, module, names, instruction, inst.words[1], inst.words[5..])) |sexpr| {
                            // Scalar geometric builtin WGSL lacks (normalize/length/
                            // distance/reflect on a scalar) — emit the equivalent.
                            try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, sexpr });
                        } else {
                            // Shared name mapping (single source of truth; honest-errors unmapped ops).
                            const func_name = try glslStd450WgslName(instruction);
                            // Build args
                            var args = std.ArrayList(u8).initCapacity(arena, 128) catch return;
                            defer args.deinit(arena);
                            for (inst.words[5..], 0..) |arg_id, ai| {
                                if (ai > 0) try args.appendSlice(arena, ", ");
                                try args.appendSlice(arena, names.get(arg_id) orelse "0");
                            }
                            // glslStd450WgslName already returns the final WGSL
                            // builtin name (incl. firstTrailingBit/firstLeadingBit
                            // for the bit-scan ops), so no further remap is needed.
                            //
                            // GLSL findMSB/findLSB always return SIGNED int (the
                            // result type is `int`/`ivec`) even for an unsigned
                            // operand (FindUMsb), but WGSL firstLeadingBit/
                            // firstTrailingBit return the ARGUMENT's type. So a
                            // `u32` arg yields a `u32` result while `rt` is `i32`
                            // (naga: "expected i32, got u32"). Wrap the bit-scan
                            // result in an explicit `rt(...)` conversion; the cast
                            // is an identity when the types already match (valid WGSL).
                            const is_bitscan = instruction == 73 or instruction == 74 or instruction == 75;
                            if (is_bitscan) {
                                try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s}({s}));\n", .{ result_name, rt, rt, func_name, args.items });
                            } else {
                                try writeInd(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                            }
                        }
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

            // Derivatives. Ordered to match the SPIR-V spec numbering:
            // plain (207-209), Fine (210-212), Coarse (213-215). WGSL has a
            // direct builtin for every one of the nine variants.
            .DPdx => try emitCall(module, names, inst, "dpdx", w, arena, indent),
            .DPdy => try emitCall(module, names, inst, "dpdy", w, arena, indent),
            .Fwidth => try emitCall(module, names, inst, "fwidth", w, arena, indent),
            // Fine-quality variants (OpDPdxFine 210 / OpDPdyFine 211 /
            // OpFwidthFine 212). Previously these fell through to the honest-
            // error else branch even though WGSL can represent them directly.
            .DPdxFine => try emitCall(module, names, inst, "dpdxFine", w, arena, indent),
            .DPdyFine => try emitCall(module, names, inst, "dpdyFine", w, arena, indent),
            .FwidthFine => try emitCall(module, names, inst, "fwidthFine", w, arena, indent),
            .DPdxCoarse => try emitCall(module, names, inst, "dpdxCoarse", w, arena, indent),
            .DPdyCoarse => try emitCall(module, names, inst, "dpdyCoarse", w, arena, indent),
            .FwidthCoarse => try emitCall(module, names, inst, "fwidthCoarse", w, arena, indent),

            // OpQuantizeToF16 (116): quantize a 32-bit float to f16
            // precision/range, then widen back to f32. WGSL's `quantizeToF16`
            // has identical semantics (componentwise on vecN<f32>), so scalar and
            // vector share this one unary-call arm. glslang never emits this from
            // GLSL — it comes from optimizers/tools/hand-written SPIR-V consumed
            // via spirvToWGSL. (#170)
            .QuantizeToF16 => try emitCall(module, names, inst, "quantizeToF16", w, arena, indent),

            // Subgroup operations (AUDIT FIX, #170 G5 Pass 2). These previously
            // emitted WGSL subgroup builtins (subgroupElect/Ballot/Broadcast/
            // BroadcastFirst/All/Any/Shuffle*/Inclusive*/Exclusive* and the scan/
            // reduction forms) directly, with NO `enable subgroups;`. naga 29.0.3
            // rejects subgroups entirely (even `enable subgroups;` is unsupported),
            // so that output was SILENT-WRONG (glslpp exited 0 but naga rejected).
            // Fail loud with a named error instead.
            .SubgroupAllKHR, .GroupNonUniformAll,
            .SubgroupAnyKHR, .GroupNonUniformAny,
            .GroupNonUniformElect,
            .GroupNonUniformBroadcast, .GroupNonUniformBroadcastFirst,
            .GroupNonUniformBallot,
            .GroupNonUniformShuffle, .GroupNonUniformShuffleXor,
            .GroupNonUniformShuffleUp, .GroupNonUniformShuffleDown,
            .GroupNonUniformIAdd, .GroupNonUniformFAdd,
            .GroupNonUniformIMul, .GroupNonUniformFMul,
            .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin,
            .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax,
            .GroupNonUniformBitwiseAnd, .GroupNonUniformLogicalAnd,
            .GroupNonUniformBitwiseOr, .GroupNonUniformLogicalOr,
            .GroupNonUniformBitwiseXor,
            => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL/naga does not support subgroup operations ({s})", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
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

            // IsInf/IsNan — WGSL has NO isInf/isNan builtins (glslpp previously
            // emitted isinf(x)/isnan(x), which naga rejects as undefined identifiers).
            .IsNan => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[3]) orelse "0";
                // NaN test: `x != x` is true iff x is NaN. WGSL comparison operators are
                // componentwise on vectors (returning vecN<bool>), so the SAME idiom covers
                // both the scalar (bool) and vector (bvecN) result — no special case needed.
                try writeInd(w, indent);
                try w.print("let {s}: {s} = ({s} != {s});\n", .{ result_name, rt, x, x });
            },
            .IsInf => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const x = names.get(inst.words[3]) orelse "0";
                if (std.mem.eql(u8, rt, "bool")) {
                    // WGSL has no isInf builtin and no infinity literal. The idiom
                    // `(x != 0.0 && x * 2.0 == x)` is true ONLY for ±inf: 0 is excluded
                    // by `x != 0.0`; a finite nonzero x has `x*2 != x`; NaN fails the
                    // `==`; the max finite value overflows under `*2.0` to inf, which
                    // `!= x`. naga-validated.
                    try writeInd(w, indent);
                    try w.print("let {s}: bool = ({s} != 0.0 && {s} * 2.0 == {s});\n", .{ result_name, x, x, x });
                } else {
                    // Vector isinf (bvecN): the same idiom, componentwise. WGSL `&` is
                    // componentwise logical-AND on bool vectors (`&&` is scalar-only), and
                    // `v != vecN(0.0)` / `v*2.0 == v` are componentwise → vecN<bool>. The
                    // zero literal must match the operand's float vector type. naga-validated.
                    const op_type_id = getTypeOf(module, inst.words[3]) orelse {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL isInf: unresolved operand type for '{s}'", .{rt}) catch null;
                        return error.UnsupportedOp;
                    };
                    const op_type = try wgslType(module, op_type_id, names, arena);
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = ({s} != {s}(0.0)) & ({s} * 2.0 == {s});\n", .{ result_name, rt, x, op_type, x, x });
                }
            },

            // CompositeInsert. SPIR-V operand order is `OpCompositeInsert <rt>
            // <result> <Object> <Composite> <Indices...>` — words[3] is the OBJECT
            // being inserted and words[4] is the base COMPOSITE. (These were read
            // swapped, so `v = OpCompositeInsert objW.w P 2` emitted `let v = P.w;
            // v.z = P;` — both backwards AND an illegal mutation of an immutable
            // `let`. Surfaced by textureProj(sampler2DShadow), whose coordinate
            // glslang builds with exactly this op.)
            .CompositeInsert => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const object = names.get(inst.words[3]) orelse "o";
                const composite = names.get(inst.words[4]) orelse "c";
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
                // Copy the base composite into a MUTABLE local, then overwrite the
                // indexed component with the inserted object (`var`, not `let`, so
                // the member assignment is legal WGSL).
                try writeInd(w, indent); try w.print("var {s}: {s} = {s};\n", .{ result_name, rt, composite });
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

            // ImageQuerySize — WGSL textureDimensions returns UNSIGNED (u32/vecNu),
            // but GLSL imageSize/textureSize is SIGNED (int/ivecN). Wrap in the
            // signed result type so the value matches its declared type (else naga
            // rejects: "expected vec2<i32>, got vec2<u32>" — silent-wrong).
            // For an ARRAYED sampler, GLSL's result is the spatial dims PLUS a
            // trailing layer count, but textureDimensions returns ONLY the spatial
            // dims — so append `i32(textureNumLayers(img))` as the last component
            // (else naga rejects "cannot cast vec2<u32> to vec3<i32>").
            .ImageQuerySize => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                const shape = imageQueryShape(module, inst.words[3]);
                try writeInd(w, indent);
                if (shape.arrayed) {
                    try w.print("let {s}: {s} = {s}({s}(textureDimensions({s})), i32(textureNumLayers({s})));\n", .{ result_name, rt, rt, signedIntVecType(shape.spatial), image, image });
                } else {
                    try w.print("let {s}: {s} = {s}(textureDimensions({s}));\n", .{ result_name, rt, rt, image });
                }
            },

            // ImageQuerySizeLod — see ImageQuerySize: convert unsigned dims to the
            // signed GLSL result type, appending textureNumLayers for arrayed
            // samplers. (textureNumLayers takes NO lod argument.)
            .ImageQuerySizeLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                const lod = names.get(inst.words[4]) orelse "0";
                const shape = imageQueryShape(module, inst.words[3]);
                try writeInd(w, indent);
                if (shape.arrayed) {
                    try w.print("let {s}: {s} = {s}({s}(textureDimensions({s}, {s})), i32(textureNumLayers({s})));\n", .{ result_name, rt, rt, signedIntVecType(shape.spatial), image, lod, image });
                } else {
                    try w.print("let {s}: {s} = {s}(textureDimensions({s}, {s}));\n", .{ result_name, rt, rt, image, lod });
                }
            },

            // ImageQueryLevels — WGSL textureNumLevels returns UNSIGNED (u32),
            // but GLSL textureQueryLevels is a SIGNED `int`, so glslpp's result
            // type (`rt`) is i32; emit `i32(textureNumLevels(t))` to convert
            // (matching the ImageQuerySize/textureDimensions wrap above). A bare
            // builtin would leave `let v: i32 = textureNumLevels(t)` → naga reject.
            .ImageQueryLevels => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = {s}(textureNumLevels({s}));\n", .{ result_name, rt, rt, image });
            },

            // ImageQuerySamples — WGSL textureNumSamples returns UNSIGNED (u32);
            // GLSL textureSamples is signed `int`. Convert like ImageQueryLevels.
            .ImageQuerySamples => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = {s}(textureNumSamples({s}));\n", .{ result_name, rt, rt, image });
            },

            // ImageQueryLod (GLSL textureQueryLod) — WGSL has NO equivalent
            // (no textureQueryLod builtin). glslpp previously emitted
            // `textureQueryLod(...)`, which naga rejects as an undefined identifier
            // (silent-wrong). Fail loud with a named error instead.
            .ImageQueryLod => {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL has no textureQueryLod equivalent (GLSL textureQueryLod is unsupported)",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            },

            // ImageGather
            .ImageGather => {
                // WGSL textureGather accepts at most ONE image operand: a single
                // CONSTANT offset (ConstOffset, mask bit 0x8), lowered to the
                // trailing const-offset argument below. EVERY other operand is
                // unrepresentable and MUST fail loud rather than silently drop
                // (dropping gathers the wrong texels while naga still accepts the
                // shorter call — silent-wrong):
                //   ConstOffsets 0x20 — the 4-offset per-texel array (textureGatherOffsets);
                //                       WGSL has no per-texel offset array. Per-texel
                //                       emulation (4 gathers) is a possible follow-up.
                //   Offset       0x10 — a RUNTIME (non-const) offset (GL_ARB_gpu_shader5);
                //                       WGSL's offset must be a const-expression.
                //   Sample       0x40 — multisample gather index; unsupported here.
                // No-operand flag bits (NonPrivateTexel 0x400, VolatileTexel 0x800,
                // SignExtend 0x1000, ZeroExtend 0x2000, Nontemporal 0x4000) also trip
                // this guard. They consume no operand word — so the word[7] indexing
                // below stays correct regardless — and could in principle ride along
                // with a lone ConstOffset, but honest-erroring them is acceptable
                // (honest-error > silent-wrong) and keeps this lowering simple.
                if (inst.words.len > 6 and (inst.words[6] & ~@as(u32, 0x8)) != 0) {
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
                // A single ConstOffset image operand (mask bit 0x8) — GLSL
                // textureGatherOffset — maps to WGSL textureGather's trailing
                // const-offset argument: textureGather(component, t, s, coords,
                // [array_index,] offset). The offset is a constant vec2<i32>
                // (SPIR-V requires ConstOffset be a constant), emitted verbatim
                // as the operand at word[7] (the only image operand once the
                // ConstOffsets/4-offset form is honest-errored above; Bias/Lod/
                // Grad are invalid on a gather). Dropping it silently gathers the
                // WRONG texels (naga accepts the shorter call). The suffix is ""
                // for a plain gather so both arrayed/non-arrayed paths share it.
                const offset_suffix: []const u8 = if (inst.words.len > 7 and (inst.words[6] & 0x8) != 0) blk: {
                    // The ConstOffset operand is a constant collectNames resolves
                    // for every ConstantComposite, so this miss is not reachable
                    // for well-formed glslang/spirv-opt output. Fail loud anyway:
                    // emitting the gather WITHOUT the offset would silently sample
                    // the wrong texels (the silent-wrong this whole arm prevents).
                    const off = names.get(inst.words[7]) orelse {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL textureGather offset operand (ConstOffset) is an unresolved constant", .{}) catch null;
                        return error.UnsupportedImageOperands;
                    };
                    break :blk try std.fmt.allocPrint(arena, ", {s}", .{off});
                } else "";
                // WGSL textureGather takes the component as the FIRST argument:
                // textureGather(component, texture, sampler, coords). Emitting the
                // GLSL order (tex, sampler, coords, component) makes naga read the
                // texture where it expects the integer component (silent-wrong).
                // Arrayed: the layer is a SEPARATE trailing i32 arg —
                // textureGather(component, t, s, coord.xy, i32(round(coord.z))).
                // Layer rounded for glslang parity (see ImageSampleImplicitLod).
                const shape = arrayedSampleShape(module, inst.words[3]);
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureGather({s}, {s}, {s}_sampler, {s}{s}, i32(round({s}{s})){s});\n", .{ result_name, rt, component, tex_name, tex_name, coord, cs, coord, ls, offset_suffix });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureGather({s}, {s}, {s}_sampler, {s}{s});\n", .{ result_name, rt, component, tex_name, tex_name, coord, offset_suffix });
                }
            },

            // ImageDrefGather — depth comparison gather
            .ImageDrefGather => {
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
                // On an ARRAYED depth texture WGSL takes the layer as a SEPARATE
                // rounded i32 array_index argument between the coordinate and the
                // depth-ref: textureGatherCompare(t, s, coord.<spatial>,
                // i32(round(coord.<layer>)), dref). glslang packs the layer into the
                // coordinate (uv,layer for 2d_array; xyz,layer for cube_array), so it
                // must be sliced out — matching the compare-SAMPLE path in
                // emitDepthCompare. (Was previously an honest error, #170.)
                const shape = depthCompareShape(module, inst.words[3]);
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureGatherCompare({s}, {s}_sampler, {s}{s}, i32(round({s}{s})), {s});\n", .{ result_name, rt, tex_name, tex_name, coord, cs, coord, ls, dref });
                } else {
                    try writeInd(w, indent); try w.print("let {s}: {s} = textureGatherCompare({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref });
                }
            },

            // Projective texture sampling (GLSL textureProj*). WGSL has no
            // projective sampling builtin, but textureProj has a CORRECT manual
            // lowering for the non-Dref forms: divide the coordinate by its LAST
            // component, then sample with the leading components matching the
            // sampler dimensionality (.x for 1D, .xy for 2D, .xyz for 3D). This
            // is naga-validated and matches GLSL semantics. (The previous handler
            // hard-coded `.xy / coord.w` — wrong for vec3 coords, where the
            // divisor is .z — and a later over-correction blanket honest-errored
            // it, regressing the working 2D case. This is dimension-aware.)
            .ImageSampleProjImplicitLod, .ImageSampleProjExplicitLod => {
                const dim = projectiveCoordDim(module, inst.words[3]) orelse {
                    // Cube / arrayed projective: no clean WGSL map — fail loud.
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no projective texture sampling for this sampler kind ({s})", .{@tagName(inst.op)}) catch null;
                    return error.UnsupportedOp;
                };
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                const coord = names.get(inst.words[4]) orelse "uv";
                // Leading components = the sampler dim (.x for 1D, .xy for 2D,
                // .xyz for 3D). The divisor = the coordinate's LAST component —
                // which depends on the coordinate VECTOR width, not the sampler
                // dim: textureProj(sampler2D, vec4) divides by .w, but
                // textureProj(sampler2D, vec3) divides by .z. Read the actual
                // operand width; fall back to dim+1 if it's not a vector type.
                const lead: []const u8 = switch (dim) {
                    1 => ".x",
                    2 => ".xy",
                    else => ".xyz",
                };
                const coord_comps = vectorComponentCount(module, inst.words[4]) orelse (dim + 1);
                const last_comp: []const u8 = switch (coord_comps) {
                    2 => ".y",
                    3 => ".z",
                    else => ".w",
                };
                try writeInd(w, indent);
                if (inst.op == .ImageSampleProjExplicitLod) {
                    const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                    try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}{s} / {s}{s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, lod });
                } else {
                    try w.print("let {s}: {s} = textureSample({s}, {s}_sampler, {s}{s} / {s}{s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp });
                }
            },

            // Projective DEPTH-COMPARE sampling (textureProj on a shadow sampler).
            // WGSL has no projective compare builtin, but textureProj has a faithful
            // manual lowering — the SAME perspective divide as the non-Dref proj
            // handler above, applied to BOTH the coordinate AND the depth reference.
            // SPIR-V's OpImageSampleProjDref divides coord and Dref by the
            // coordinate's last component, so for textureProj(sampler2DShadow, P) —
            // which glslang encodes as coord=(P.x,P.y,P.w,P.w), Dref=P.z — the result
            // is textureSampleCompare(t, s, P.xy / P.w, P.z / P.w). Dropping the Dref
            // divide would be silent-wrong (naga accepts it). Cube/arrayed shadow
            // proj has no clean map (projectiveCoordDim → null) and still fails loud.
            .ImageSampleProjDrefImplicitLod, .ImageSampleProjDrefExplicitLod => {
                const dim = projectiveCoordDim(module, inst.words[3]) orelse {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no projective depth-compare sampling for this sampler kind ({s})", .{@tagName(inst.op)}) catch null;
                    return error.UnsupportedOp;
                };
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                // Leading spatial components = the sampler dim (.x/.xy/.xyz). The
                // divisor = the coordinate's LAST component (depends on the coord
                // vector width, not the sampler dim) — exactly as the non-Dref path.
                const lead: []const u8 = switch (dim) {
                    1 => ".x",
                    2 => ".xy",
                    else => ".xyz",
                };
                const coord_comps = vectorComponentCount(module, inst.words[4]) orelse (dim + 1);
                const last_comp: []const u8 = switch (coord_comps) {
                    2 => ".y",
                    3 => ".z",
                    else => ".w",
                };
                // ProjExplicitLod's LOD (must be 0 for a shadow sample) is dropped:
                // WGSL has no projective-compare-with-LOD builtin, and the implicit
                // form already samples the base level for depth textures.
                try writeInd(w, indent);
                try w.print("let {s}: {s} = textureSampleCompare({s}, {s}_sampler, {s}{s} / {s}{s}, {s} / {s}{s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, dref, coord, last_comp });
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

            // ArrayLength — runtime SSBO array `.length()`. WGSL: arrayLength(&buf.member),
            // returning u32 (matching the uint result type). words[3]=struct (block-var)
            // pointer, words[4]=runtime-array member index. (#294)
            .ArrayLength => {
                if (inst.words.len < 5) return error.UnsupportedOp;
                const rt = try wgslType(module, inst.words[1], names, arena); // u32
                const result_name = names.get(inst.words[2]) orelse "v";
                const buf_name = names.get(inst.words[3]) orelse "buf";
                const member_idx = inst.words[4];
                var struct_id: u32 = 0;
                if (getTypeOf(module, inst.words[3])) |ptr_ty| {
                    if (getDef(module, ptr_ty)) |ptr| {
                        if (ptr.op == .TypePointer and ptr.words.len > 3) struct_id = ptr.words[3];
                    }
                }
                // Can't resolve the struct member name (malformed/external SPIR-V) →
                // honest-error rather than emit `arrayLength(&buf.arr)` against a
                // nonexistent member (naga would reject it).
                if (struct_id == 0) return error.UnsupportedOp;
                var mbuf: [32]u8 = undefined;
                const member_name = getMemberName(module, struct_id, member_idx, &mbuf);
                try writeInd(w, indent);
                try w.print("let {s}: {s} = arrayLength(&{s}.{s});\n", .{ result_name, rt, buf_name, member_name });
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
                if (atomicPtrIsImage(module, names, inst.words[3])) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no image atomic operations (atomicExchange on a storage image)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                // OpAtomicExchange layout: [3]=pointer [4]=scope [5]=semantics [6]=value.
                // The value is words[6], NOT words[4] (which is the scope — emitting it
                // stored the scope constant instead of the data: silent-wrong).
                const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = atomicExchange(&{s}, {s});\n", .{ rn, rt, ptr, val });
            },
            .AtomicCompareExchange => {
                if (atomicPtrIsImage(module, names, inst.words[3])) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no image atomic operations (atomicCompareExchangeWeak on a storage image)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                // OpAtomicCompareExchange operand layout (after result-type + result-id):
                //   [3]=pointer [4]=scope [5]=Equal-semantics [6]=Unequal-semantics
                //   [7]=Value (the NEW value) [8]=Comparator (the COMPARE value).
                // WGSL is atomicCompareExchangeWeak(ptr, compare, new), so compare comes
                // from words[8] (the comparator) and new from words[7] (the value). The
                // previous code read the compare arg from words[6], the Unequal-semantics
                // operand — emitting a memory-semantics constant as the compare value
                // (silent-wrong: naga accepts it but the comparison is against the wrong value).
                const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
                const cmp = if (inst.words.len > 8) names.get(inst.words[8]) orelse "0" else "0";
                try writeInd(w, indent); try w.print("let {s}: {s} = atomicCompareExchangeWeak(&{s}, {s}, {s}).old_value;\n", .{ rn, rt, ptr, cmp, val });
            },

            // QCOM image-processing (GL_QCOM_image_processing: textureWeightedQCOM,
            // textureBoxFilterQCOM, textureBlockMatch{SAD,SSD}QCOM). WGSL has no
            // equivalent — fail loud rather than fall through to the placeholder
            // `var v: T;` below (which produces silent-wrong / redefinition WGSL).
            .ImageSampleWeightedQCOM, .ImageBoxFilterQCOM, .ImageBlockMatchSSDQCOM, .ImageBlockMatchSADQCOM => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no QCOM image-processing op ({s})", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            },

            // Fragment-shader interlock barriers (GL_ARB/EXT_fragment_shader_interlock).
            // WGSL has no fragment-shader interlock. The interlock execution mode is
            // already caught earlier, but the barrier opcodes themselves were being
            // silently dropped; honest-error them as defense-in-depth so an interlock
            // shader can never produce silently-unsynchronised WGSL.
            .BeginInvocationInterlockEXT, .EndInvocationInterlockEXT => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no fragment-shader interlock ({s})", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            },

            else => {
                // OpIAddCarry (149) / OpISubBorrow (150) — GLSL uaddCarry/usubBorrow.
                // `spirv.Op` does not name them (non-exhaustive enum), so they reach
                // the else arm and must be matched by opcode number. Each yields a
                // 2-member {result, carry|borrow} struct whose ONLY consumer is
                // OpCompositeExtract; there is no struct-returning WGSL builtin, so the
                // result id needs no WGSL value here — every extracted member is
                // recomputed directly from the operands in the CompositeExtract arm
                // (member 0 = the wrapping add/sub, member 1 = the carry/borrow via
                // `select`). The `dead_extracts`/inline pre-scans are guarded so the
                // member extracts survive to reach that arm. (#170)
                if (isAddCarryOrSubBorrow(inst.op)) continue;

                // No mapping for this op in the main emit path. The old fallback
                // emitted `// unhandled op N` + `var <name>: T;` — an UNINITIALIZED
                // var (garbage value) that is nonetheless syntactically valid WGSL,
                // so naga accepts it: a textbook silent-wrong. Fail loud instead.
                // (Verified: no shader in the conformance corpus reaches here — a
                // grep for "unhandled op" over the full corpus output is empty — so
                // flipping this to an honest error regresses nothing. If a future
                // REPRESENTABLE op surfaces here, give it a real naga-validated arm
                // rather than re-introducing the placeholder.)
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: unsupported op '{s}' (opcode {d}) in main emit path", .{ opName(inst.op), @intFromEnum(inst.op) }) catch null;
                return error.UnsupportedOp;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Emit helpers
// ---------------------------------------------------------------------------

/// Emit OpOuterProduct as an explicit WGSL matrix construction. SPIR-V
/// `OpOuterProduct %resultMatrix %u %v` produces a matrix whose column i is the
/// R-vector `u` scaled by the scalar `v[i]`; the result matrix has `v`'s
/// component count (C) columns of `u`'s component count (R) rows — i.e. a
/// `matCxR` (WGSL `matCxRf`). WGSL has no outerProduct builtin, so we emit
/// `matCxRf(u * v.x, u * v.y, ...)`. naga-validated for square and non-square.
fn emitOuterProduct(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const u = names.get(inst.words[3]) orelse "u";
    const v = names.get(inst.words[4]) orelse "v";
    // Column count = the result matrix's column count = v's component count.
    const mt = getDef(module, inst.words[1]) orelse return error.UnsupportedOp;
    if (mt.op != .TypeMatrix or mt.words.len < 4) return error.UnsupportedOp;
    const cols = mt.words[3];
    var buf = std.ArrayList(u8).initCapacity(arena, 96) catch return error.OutOfMemory;
    defer buf.deinit(arena);
    try buf.writer(arena).print("{s}(", .{rt});
    var i: u32 = 0;
    while (i < cols) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, ", ");
        // v[i] selected via swizzle for a vector (x/y/z/w).
        try buf.writer(arena).print("{s} * {s}.{s}", .{ u, v, common.swizzleChar(i) });
    }
    try buf.appendSlice(arena, ")");
    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, buf.items });
}

// #254: if both operands of a float +/-/*/÷/% are 32-bit float constants and the IEEE
// result is non-finite, return its u32 bit pattern (else null). The frontend does NOT
// fold a constant division by zero, so `1.0/0.0` reaches here as an OpFDiv of two
// constants; emitted verbatim it becomes `1.0f / 0.0f`, which naga const-evaluates and
// rejects ("Float literal is infinite"). Folding it to bitcast<f32>(0x..u) yields a
// runtime value naga accepts (a follow-up to #252's constant handling).
fn f32ConstVal(module: *const ParsedModule, id: u32) ?f32 {
    const ci = common.getDef(module, id) orelse return null;
    if (ci.op != .Constant or ci.words.len <= 3) return null;
    const ti = common.getDef(module, ci.words[1]) orelse return null;
    if (ti.op != .TypeFloat or !(ti.words.len > 2 and ti.words[2] == 32)) return null;
    return @bitCast(ci.words[3]);
}

// #258: helpers for the integer constant-division-by-zero honest-error guard.
fn isConstant(module: *const ParsedModule, id: u32) bool {
    const ci = common.getDef(module, id) orelse return false;
    return ci.op == .Constant;
}

fn isConstantZero(module: *const ParsedModule, id: u32) bool {
    const ci = common.getDef(module, id) orelse return false;
    // The literal word for a scalar int 0 / float +0.0 is the all-zero bit pattern.
    // Limitation: a 64-bit integer constant `0x1_00000000` also has words[3]==0; this
    // would false-positive, but glslpp honest-errors 64-bit integer types in the
    // frontend (semantic.zig) before they reach the WGSL backend, so it is unreachable
    // for glslpp's own output (and a false honest-error is preferable to silent-wrong
    // for hand-fed external SPIR-V).
    return ci.op == .Constant and ci.words.len > 3 and ci.words[3] == 0;
}

fn isIntegerType(module: *const ParsedModule, type_id: u32) bool {
    const ti = common.getDef(module, type_id) orelse return false;
    return ti.op == .TypeInt;
}

fn constFoldNonFiniteFloat(module: *const ParsedModule, inst: Instruction) ?u32 {
    if (inst.words.len < 5) return null;
    const a = f32ConstVal(module, inst.words[3]) orelse return null;
    const b = f32ConstVal(module, inst.words[4]) orelse return null;
    const r: f32 = switch (inst.op) {
        .FAdd => a + b,
        .FSub => a - b,
        .FMul => a * b,
        .FDiv => a / b,
        // Both FMod and FRem are emitted as WGSL `%` (truncated remainder == Zig
        // @rem); for the non-finite case we fold (e.g. `mod(1.0, 0.0)` → NaN) the
        // two agree, and finite results are never folded so the FMod/FRem operator
        // discrepancy is irrelevant here.
        .FMod, .FRem => @rem(a, b),
        else => return null,
    };
    if (std.math.isFinite(r)) return null;
    return @bitCast(r);
}

fn emitBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    // #254: const-fold a non-finite scalar-float arithmetic result to a bitcast literal
    // (runtime context — emitBinOp only emits function-body `let` statements). Runs
    // before the literal-zero band-aid below so `1.0/0.0` folds to +inf, not 0.0.
    if (std.mem.eql(u8, rt, "f32")) {
        if (constFoldNonFiniteFloat(module, inst)) |bits| {
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = bitcast<f32>(0x{x:0>8}u);\n", .{ result_name, rt, bits });
            return;
        }
    }
    // #258: a division/remainder whose DIVISOR is a constant zero. (The float
    // const/const case was folded to a bitcast above, #254.) What remains:
    //   - runtime dividend / const-zero → a valid RUNTIME division naga accepts
    //     (WGSL defines integer `x / 0 == x`; float `x / 0.0` is a runtime inf) →
    //     emit normally;
    //   - INTEGER const dividend / const-zero → naga const-evaluates and rejects
    //     ("Division by zero"), and WGSL has no integer inf/nan, so it is
    //     unrepresentable → honest-error. (The old band-aid emitted `0.0` here,
    //     which is itself naga-invalid for an integer result.)
    if (inst.words.len >= 5 and
        (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) and
        isConstantZero(module, inst.words[4]) and
        isConstant(module, inst.words[3]) and
        isIntegerType(module, inst.words[1]))
    {
        last_error_detail = std.fmt.bufPrint(
            &last_error_detail_buf,
            "integer constant division by zero has no WGSL representation",
            .{},
        ) catch null;
        return error.UnsupportedOp;
    }
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    // Wrap compound expressions in parens for correct precedence
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op, rhs });
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
fn emitSimpleInstruction(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, indent: u32, wrapped_members: *const WrappedUniformMemberMap, matrix_outputs: *const std.AutoHashMap(u32, MatrixOutput)) !void {
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
            // #170 (H): a whole-matrix store to a flattened matrix output that
            // lands here (a switch/conditional replay body) cannot be split
            // correctly — the sibling `default` case body is dropped by a
            // separate frontend miscompile, so emitting per-column writes would
            // turn an honest naga-reject into silent-wrong. Emitting the raw
            // `vertex_out.M = …` is naga-invalid (no member `M`; it was
            // flattened to `M_0…M_{n}`). Fail loud. (Out-of-corpus.)
            if (matrix_outputs.contains(inst.words[1])) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL matrix-output flattening does not support a matrix store inside a switch/conditional case body", .{}) catch null;
                return error.UnsupportedOp;
            }
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
                const expr = buildAccessExpr(module, names, base_id, inst.words[4..], alloc, wrapped_members) catch return;
                if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
            }
        },
        .CompositeExtract => {
            // Build a type-aware access expression (vec swizzle / struct member /
            // array index) and store it inline in `names`, emitting NO statement
            // — mirroring the main emit path. Without this case the replay path
            // fell to the generic fallback, leaking `var <expr>: T =
            // CompositeExtract(...)` (the opcode name as a call AND an access
            // expression used as a `var` name) which naga rejects.
            if (inst.words.len < 4) return;
            const result_id = inst.words[2];
            const composite = names.get(inst.words[3]) orelse "c";
            var expr = std.ArrayList(u8).initCapacity(alloc, 64) catch return;
            errdefer expr.deinit(alloc);
            expr.appendSlice(alloc, composite) catch return;
            var current_type: ?u32 = resolveTypeOf(module, inst.words[3]);
            if (current_type == null) {
                const comp_def = getDef(module, inst.words[3]);
                if (comp_def) |cd| {
                    if (cd.words.len > 1) {
                        const rt_inst = getDef(module, cd.words[1]);
                        if (rt_inst) |rti| {
                            current_type = if (rti.op == .TypePointer and rti.words.len > 3) rti.words[3] else cd.words[1];
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
                            expr.print(alloc, ".{s}", .{mname}) catch return;
                            current_type = if (idx + 2 < cti.words.len) cti.words[idx + 2] else null;
                            continue;
                        } else if (cti.op == .TypeVector) {
                            const sw = switch (idx) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" };
                            expr.appendSlice(alloc, sw) catch return;
                            current_type = if (cti.words.len > 2) cti.words[2] else null;
                            continue;
                        } else if (cti.op == .TypeMatrix or cti.op == .TypeArray) {
                            expr.print(alloc, "[{d}]", .{idx}) catch return;
                            current_type = if (cti.words.len > 2) cti.words[2] else null;
                            continue;
                        }
                    }
                }
                expr.print(alloc, "[{d}]", .{idx}) catch return;
            }
            const owned = expr.toOwnedSlice(alloc) catch return;
            if (try names.fetchPut(result_id, owned)) |old| alloc.free(old.value);
        },
        .Select => {
            // WGSL `select(false, true, cond)`. Without this case the replay path
            // leaked the opcode name as a call (`Select(...)`), which naga rejects.
            if (inst.words.len < 6) return;
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const cond = names.get(inst.words[3]) orelse "c";
            const true_val = names.get(inst.words[4]) orelse "t";
            const false_val = names.get(inst.words[5]) orelse "f";
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
        },
        .Bitcast => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "0";
            try writeIndentStatic(w, indent); try w.print("let {s}: {s} = bitcast<{s}>({s});\n", .{ result_name, rt, rt, val });
        },
        // IsNan/IsInf must be handled here too (the loop/switch REPLAY path), or
        // `isnan`/`isinf` used in a loop CONDITION (deferred into the loop-header replay
        // range) honest-errors despite the main-path lowering. Mirrors the emitBody arms
        // exactly: scalar AND vector via the componentwise idioms. (#170)
        .IsNan => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const x = names.get(inst.words[3]) orelse "0";
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = ({s} != {s});\n", .{ result_name, rt, x, x });
        },
        .IsInf => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const x = names.get(inst.words[3]) orelse "0";
            if (std.mem.eql(u8, rt, "bool")) {
                try writeIndentStatic(w, indent);
                try w.print("let {s}: bool = ({s} != 0.0 && {s} * 2.0 == {s});\n", .{ result_name, x, x, x });
            } else {
                const op_type_id = getTypeOf(module, inst.words[3]) orelse {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL isInf: unresolved operand type for '{s}'", .{rt}) catch null;
                    return error.UnsupportedOp;
                };
                const op_type = try wgslType(module, op_type_id, names, arena);
                try writeIndentStatic(w, indent);
                try w.print("let {s}: {s} = ({s} != {s}(0.0)) & ({s} * 2.0 == {s});\n", .{ result_name, rt, x, op_type, x, x });
            }
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
                if (instruction == 34) {
                    // MatrixInverse → generated spvInverseN helper (mirrors the
                    // main emit path; WGSL has no inverse builtin).
                    const dim = inverseMatrixDim(module, inst.words[1]) orelse {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL inverse() unsupported for this matrix (only square mat2/mat3/mat4)", .{}) catch null;
                        return error.UnsupportedExtInst;
                    };
                    const m = names.get(inst.words[5]) orelse "m";
                    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = spvInverse{d}({s});\n", .{ result_name, rt, dim, m });
                    return;
                }
                if (scalarGeomLower(arena, module, names, instruction, inst.words[1], inst.words[5..])) |sexpr| {
                    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, sexpr });
                    return;
                }
                const func_name = try glslStd450WgslName(instruction);
                var args = std.ArrayList(u8).initCapacity(arena, 128) catch return;
                defer args.deinit(arena);
                for (inst.words[5..], 0..) |arg_id, ai| {
                    if (ai > 0) try args.appendSlice(arena, ", ");
                    try args.appendSlice(arena, names.get(arg_id) orelse "0");
                }
                // Bit-scan ops (FindILsb 73 / FindSMsb 74 / FindUMsb 75): GLSL
                // returns signed int, WGSL firstTrailingBit/firstLeadingBit return
                // the arg type — wrap in an explicit `rt(...)` conversion (mirrors
                // the main emit path; identity cast when types already match).
                const is_bitscan = instruction == 73 or instruction == 74 or instruction == 75;
                if (is_bitscan) {
                    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s}({s}({s}));\n", .{ result_name, rt, rt, func_name, args.items });
                } else {
                    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                }
            }
        },
        .OuterProduct => try emitOuterProduct(module, names, inst, w, arena, indent),
        .CompositeConstruct => {
            // Loop/switch-replay path: a CompositeConstruct whose result is USED
            // (not inlined into a store) must construct via its result type, e.g.
            // `vec4f(a, b, c, d)`. Previously it fell to the generic fallback which
            // emitted the opcode tag name `CompositeConstruct(...)` — a bare
            // identifier naga rejects ("no definition in scope"). Mirrors the main
            // emit path's general case.
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
            defer args.deinit(arena);
            for (inst.words[3..], 0..) |comp_id, ci| {
                if (ci > 0) try args.appendSlice(arena, ", ");
                try args.appendSlice(arena, names.get(comp_id) orelse "0");
            }
            try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, args.items });
        },
        .SelectionMerge, .LoopMerge => {
            // Structured control-flow merge hints — they carry no result id and
            // are consumed by the enclosing switch/if/loop replay. Emit nothing
            // (otherwise the generic fallback below leaks the opcode name as a
            // value, e.g. `let v = SelectionMerge();`, which naga rejects).
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
            // No mapping for this op in the switch/loop replay path. The old
            // fallback emitted `var <name>: T = <OpcodeName>(args)` — a call to a
            // non-existent WGSL function (e.g. `VectorShuffle(...)`), which naga
            // always rejects (silent-wrong). Fail loud instead. (No naga-passing
            // shader can reach here: the leaked opcode name is never valid WGSL.)
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: unsupported op '{s}' (opcode {d}) in switch/loop replay path", .{ opName(inst.op), @intFromEnum(inst.op) }) catch null;
            return error.UnsupportedOp;
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
        .LogicalEqual => "==",
        .LogicalNotEqual => "!=",
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

// (emitSubgroupArith removed in #170 G5 Pass 2: subgroup ops are now an honest
// error — naga 29.0.3 has no subgroup support — so no subgroup builtin is ever
// emitted. See the consolidated subgroup arm in emitBody.)

/// True iff an OpAtomic* pointer operand resolves to an IMAGE texel (the pointer
/// is produced by OpImageTexelPointer, which the WGSL backend names as a
/// `textureLoad(...)` rvalue). WGSL has NO image atomics: emitting
/// `atomicAdd(&textureLoad(img, ...))` makes naga reject ("operand of & must be a
/// reference"). The caller must honest-error such atomics rather than emit that
/// silent-wrong WGSL. (Buffer/workgroup atomics on a real pointer are fine.)
fn atomicPtrIsImage(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32) bool {
    if (getDef(module, ptr_id)) |d| {
        if (d.op == .ImageTexelPointer) return true;
    }
    // Defensive: even if a future path renames it, an image texel pointer is
    // spelled as a textureLoad rvalue — never a valid `&`-able reference.
    if (names.get(ptr_id)) |n| {
        if (std.mem.indexOf(u8, n, "textureLoad(") != null) return true;
    }
    return false;
}

fn emitAtomicBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    if (atomicPtrIsImage(module, names, inst.words[3])) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no image atomic operations (atomic{s} on a storage image)", .{op}) catch null;
        return error.UnsupportedOp;
    }
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const ptr = names.get(inst.words[3]) orelse "ptr";
    // OpAtomic{IAdd,ISub,And,Or,Xor,SMin,UMin,SMax,UMax,FAddEXT} layout:
    //   [3]=pointer [4]=scope [5]=semantics [6]=value. The value is words[6], NOT
    //   words[4] (the scope). Reading words[4] emitted the scope constant (Device == 1)
    //   as the operand — silent-wrong for every value != the scope.
    const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
    // The atomic RMW result is an immutable SSA value — bind with `let`, matching the
    // AtomicExchange / AtomicCompareExchange emitters (was `var`, an inconsistency).
    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = atomic{s}(&{s}, {s});\n", .{ result_name, rt, op, ptr, val });
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

// Detect a cycle in the OpFunctionCall graph (direct or mutual recursion).
// WGSL forbids recursion of any kind, so a cycle means the module cannot be
// represented and must be honest-errored rather than emitted. Returns true if
// any reachable cycle exists. Conservative: allocation failures return false
// (the worst case is naga catching the recursion downstream, never silent-wrong
// acceptance of something this missed).
fn callGraphHasCycle(module: *const ParsedModule, alloc: std.mem.Allocator) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var adj = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(a);
    var cur: u32 = 0;
    for (module.instructions) |inst| {
        switch (inst.op) {
            .Function => if (inst.words.len >= 3) {
                cur = inst.words[2];
                const gop = adj.getOrPut(cur) catch return false;
                if (!gop.found_existing) gop.value_ptr.* = .{};
            },
            .FunctionEnd => cur = 0,
            .FunctionCall => if (inst.words.len >= 4 and cur != 0) {
                const gop = adj.getOrPut(cur) catch return false;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.append(a, inst.words[3]) catch return false;
            },
            else => {},
        }
    }

    // Iterative DFS with white(absent)/gray(1)/black(2) coloring; a gray
    // back-edge is a cycle.
    var color = std.AutoHashMap(u32, u8).init(a);
    var it = adj.keyIterator();
    while (it.next()) |kp| {
        if ((color.get(kp.*) orelse 0) != 0) continue;
        const Frame = struct { node: u32, i: usize };
        var stack = std.ArrayListUnmanaged(Frame){};
        stack.append(a, .{ .node = kp.*, .i = 0 }) catch return false;
        color.put(kp.*, 1) catch return false;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const neighbors: []const u32 = if (adj.get(top.node)) |list| list.items else &.{};
            if (top.i < neighbors.len) {
                const nb = neighbors[top.i];
                top.i += 1;
                const c = color.get(nb) orelse 0;
                if (c == 1) return true; // gray back-edge → cycle
                if (c == 0) {
                    color.put(nb, 1) catch return false;
                    stack.append(a, .{ .node = nb, .i = 0 }) catch return false;
                }
            } else {
                color.put(top.node, 2) catch return false;
                _ = stack.pop();
            }
        }
    }
    return false;
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

