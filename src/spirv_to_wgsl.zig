// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → WGSL (WebGPU Shading Language) cross-compiler backend.

const std = @import("std");
const compat = @import("compat.zig");
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
threadlocal var last_error_detail_buf: [384]u8 = undefined;

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

/// Single-entry-block-store private-var forwarding (see
/// buildSingleStorePrivateForwarding): var id -> stored value id. Threadlocal
/// file state like the flags above because BOTH instruction emitters need the
/// same decision for one compile: the main emitBody and emitSimpleInstruction
/// (the switch/loop replay emitter, 9 call sites). Rebuilt at every
/// `spirvToWGSL` entry.
threadlocal var forward_private_stores: std.AutoHashMapUnmanaged(u32, u32) = .empty;

/// Square dimension (2/3/4) of the matrix operand of a MatrixInverse ExtInst, or
/// null if the operand is not a square float matrix of a supported size. Used by
/// both the pre-emit helper-detection scan and the ExtInst arms so the chosen
/// helper name (spvInverse2/3/4) and the emitted helper agree.
/// Format an OpSwitch case literal with the SELECTOR's signedness.
///
/// SPIR-V stores the literal as the selector's raw bit pattern, so for a signed
/// selector 0xFFFFFFFF means -1, not 4294967295. Metal rejects the wide literal
/// outright ("case value evaluates to 4294967295, which cannot be narrowed to
/// type 'int'"), and the C-family backends silently emit a case the selector can
/// never equal -- that arm just never runs. graphicsfuzz_082 and _026 both carry
/// such a case; neither reached this code until the #early-return-arm fix stopped
/// refusing them.
fn switchCaseLiteral(module: *const ParsedModule, selector_id: u32, cv: u32) i64 {
    const tid = getTypeOf(module, selector_id) orelse return cv;
    const t = getDef(module, tid) orelse return cv;
    if (t.op == .TypeInt and t.words.len > 3 and t.words[3] != 0) {
        return @as(i32, @bitCast(cv));
    }
    return cv;
}

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
        1 => "Round",
        2 => "RoundEven",
        3 => "Trunc",
        4 => "FAbs",
        5 => "SAbs",
        6 => "FSign",
        7 => "SSign",
        8 => "Floor",
        9 => "Ceil",
        10 => "Fract",
        11 => "Radians",
        12 => "Degrees",
        13 => "Sin",
        14 => "Cos",
        15 => "Tan",
        16 => "Asin",
        17 => "Acos",
        18 => "Atan",
        19 => "Sinh",
        20 => "Cosh",
        21 => "Tanh",
        22 => "Asinh",
        23 => "Acosh",
        24 => "Atanh",
        25 => "Atan2",
        26 => "Pow",
        27 => "Exp",
        28 => "Log",
        29 => "Exp2",
        30 => "Log2",
        31 => "Sqrt",
        32 => "InverseSqrt",
        33 => "Determinant",
        34 => "MatrixInverse",
        35 => "Modf",
        36 => "ModfStruct",
        37 => "FMin",
        38 => "UMin",
        39 => "SMin",
        40 => "FMax",
        41 => "UMax",
        42 => "SMax",
        43 => "FClamp",
        44 => "UClamp",
        45 => "SClamp",
        46 => "FMix",
        47 => "IMix",
        48 => "Step",
        49 => "SmoothStep",
        50 => "Fma",
        51 => "Frexp",
        52 => "FrexpStruct",
        53 => "Ldexp",
        54 => "PackSnorm4x8",
        55 => "PackUnorm4x8",
        56 => "PackSnorm2x16",
        57 => "PackUnorm2x16",
        58 => "PackHalf2x16",
        59 => "PackDouble2x32",
        60 => "UnpackSnorm2x16",
        61 => "UnpackUnorm2x16",
        62 => "UnpackHalf2x16",
        63 => "UnpackSnorm4x8",
        64 => "UnpackUnorm4x8",
        65 => "UnpackDouble2x32",
        66 => "Length",
        67 => "Distance",
        68 => "Cross",
        69 => "Normalize",
        70 => "FaceForward",
        71 => "Reflect",
        72 => "Refract",
        73 => "FindILsb",
        74 => "FindSMsb",
        75 => "FindUMsb",
        76 => "InterpolateAtCentroid",
        77 => "InterpolateAtSample",
        78 => "InterpolateAtOffset",
        79 => "NMin",
        80 => "NMax",
        81 => "NClamp",
        else => "Unknown",
    };
}

/// Safe display name for an `Op` in a diagnostic. `Op` is a NON-EXHAUSTIVE enum
/// (`_,`), so a SPIR-V opcode zioshade does not name (e.g. OpIAddCarry=149 from
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

/// OpTerminateInvocation = 4416, SPIR-V 1.6's replacement for OpKill (and the
/// SPV_KHR_terminate_invocation form every recent glslang emits for `discard`
/// when targeting 1.6). `spirv.Op` is non-exhaustive and does NOT name it, so
/// like OpIAddCarry above it has to be matched by raw opcode number. It is a
/// DISCARD-LIKE BLOCK TERMINATOR, which is what the uniformity prepass cares
/// about: see the classification note in `UniformityAnalysis.parse`.
fn isTerminateInvocation(op: spirv.Op) bool {
    return @intFromEnum(op) == 4416;
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

/// Record the detail for a loop nested inside a switch case body, then return
/// the honest error. The `.Switch` handler replays case bodies through a
/// limited emitter (emitSimpleInstruction) that cannot construct loops, so a
/// loop nested in a case (directly or inside a nested if) would be silently
/// DROPPED. Fail loud rather than miscompile. GLSL/MSL/HLSL emit this correctly;
/// full loop-in-case emission for WGSL is a tracked follow-up. Revisit if the
/// construct appears in real target workloads. (#wgsl-loop-in-switch-case)
fn recordUnsupportedLoopInSwitchCase() error{UnsupportedLoopInSwitchCase} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "a loop nested inside a switch case body cannot be lowered to WGSL yet (the case-body replay cannot construct loops); hoist the loop outside the switch or rewrite the case as an if-chain",
        .{},
    ) catch null;
    return error.UnsupportedLoopInSwitchCase;
}

/// Honest-error for a case-body terminator whose branch target is neither the
/// switch's merge, the enclosing loop's continue, a fallthrough case label, nor
/// a nested-if merge: an INTERNAL same-case block (the arm walks broke on ANY
/// OpBranch, silently dropping everything after it -- exit 0, truncated case
/// body) or an outer construct such as the enclosing loop's merge (a
/// multi-level break WGSL cannot spell without a flag variable). Fail loud
/// rather than truncate; following internal blocks is the region-walker's job.
fn recordUnsupportedSwitchCaseExit(target: u32) error{UnsupportedSwitchCaseExit} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "a switch case body branches to block %{d}, an internal block or outer-construct target (not the switch merge, loop continue, fallthrough case, or nested-if merge); the case-body walk cannot follow it and would silently truncate the case (rewrite as a straight-line case, or hoist the branch chain)",
        .{target},
    ) catch null;
    return error.UnsupportedSwitchCaseExit;
}

/// Honest-error for a switch nested inside a switch case body. The `.Switch` case-body
/// replay (default arm at ~6166, case arm at ~6278) does `if (dinst.op == .Switch) break;`
/// -- it stops at the inner OpSwitch without emitting it OR anything after, so the inner
/// switch and its trailing case-body instructions are silently DROPPED (nested_switch:
/// outv stayed 0 instead of 10/11/12/...). The replay cannot construct a nested switch
/// (it would need a recursive emitter, not emitSimpleInstruction). Fail loud rather than
/// miscompile. GLSL/MSL/HLSL emit this correctly (emitBlock recurses). Full nested-switch
/// emission for WGSL is a tracked follow-up. (#wgsl-nested-switch-in-switch-case)
fn recordUnsupportedNestedSwitchInSwitchCase() error{UnsupportedNestedSwitchInSwitchCase} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "a switch nested inside a switch case body cannot be lowered to WGSL yet (the case-body replay stops at the inner OpSwitch and would silently drop it); flatten the inner switch into an if-chain or hoist it into a helper function",
        .{},
    ) catch null;
    return error.UnsupportedNestedSwitchInSwitchCase;
}

/// Record the detail for a derivative builtin that sits in non-uniform control
/// flow, then return the honest error. (#685, #wgsl-uniformity-8k2-derivatives)
///
/// WGSL gates dpdx/dpdy/fwidth and their Coarse/Fine variants on uniform
/// control flow exactly like the implicit-Lod sampling builtins (tint: "'dpdx'
/// must only be called from uniform control flow"), and unlike sampling there
/// is NO lowering: WGSL has no explicit-derivative form to pin the operands of
/// (no analog of the textureSampleLevel(..., 0.0) downgrade), so the only
/// emittable spelling is the gated builtin and the consumer rejects the whole
/// module, rendering nothing. Emitting it anyway was the black-shader failure
/// mode this class caused; refuse loud instead, naming the hoist workaround.
fn recordUnsupportedNonuniformDerivative() error{UnsupportedNonuniformDerivative} {
    last_error_detail = std.fmt.bufPrint(
        &last_error_detail_buf,
        "a derivative (dpdx/dpdy/fwidth, Coarse/Fine included) is called after control flow has diverged; WGSL gates derivatives on uniform control flow like implicit-Lod sampling and has no explicit-derivative form to lower to, so the consumer rejects the shader (a black render). Workaround: hoist the derivative above the branch, or compute it unconditionally and select the result",
        .{},
    ) catch null;
    return error.UnsupportedNonuniformDerivative;
}

/// Single source of truth: zioshade's internal GLSL.std.450 opcode number → WGSL
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
        // Geometric — zioshade numbering starts at 66.
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
    /// Applied to @binding only; @group is the SPIR-V descriptor set (1:1), so a
    /// shift never changes @group.
    binding_shift: i32 = 0,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    return common.getDef(module, id);
}

/// True if `candidate` is already used as the WGSL name of some variable OTHER than
/// `except_id`. Used to keep a synthesized identifier (e.g. an anonymous-block
/// variable name) collision-free against every other name in the module. (#170)
fn nameInUse(names: *const std.AutoHashMap(u32, []const u8), candidate: []const u8, except_id: u32) bool {
    var it = names.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == except_id) continue;
        if (std.mem.eql(u8, e.value_ptr.*, candidate)) return true;
    }
    return false;
}

/// For a CompositeExtract whose source is an OpExtInst FrexpStruct (52) / ModfStruct
/// (36), returns the WGSL builtin result-struct field name for member `idx`: index 0
/// is `.fract`, index 1 is `.exp` (frexp) / `.whole` (modf). glslang names the SPIR-V
/// struct type `ResType` (UNDEFINED in WGSL) and emits no OpMemberName, so the generic
/// member lookup would produce `._0`/`._1`; this maps to the named builtin fields.
/// Returns null when the source is not a frexp/modf struct result. (#170)
fn frexpModfField(module: *const ParsedModule, source_id: u32, idx: u32) ?[]const u8 {
    const d = getDef(module, source_id) orelse return null;
    if (d.op != .ExtInst or d.words.len < 5) return null;
    return switch (d.words[4]) {
        52 => switch (idx) {
            0 => "fract",
            1 => "exp",
            else => null,
        }, // FrexpStruct
        36 => switch (idx) {
            0 => "fract",
            1 => "whole",
            else => null,
        }, // ModfStruct
        else => null,
    };
}

/// True if the block labeled `label` is a pure unconditional-branch trampoline to
/// `target` — i.e. `OpLabel <label>` immediately followed by `OpBranch <target>`,
/// with no value/side-effect instruction in between. glslang `-V` (unoptimized)
/// emits `if (cond) break;` / `if (cond) continue;` as such a trampoline: the
/// selection's conditional branch points at a SEPARATE block that does nothing but
/// `OpBranch <loop_merge>` (break) or `OpBranch <loop_continue>` (continue). The
/// structurizer's break detection otherwise matches only the DIRECT form (the
/// conditional branch target IS the loop merge), so without this the trampoline
/// branch is dropped → an empty `if (cond) { }` = silent-wrong. (#170)
/// #switch-fallthrough (WGSL): true iff `lbl` is a case/default target of the OpSwitch
/// whose words are `switch_words` (words[2]=default, words[4,6,…]=case targets). Used to
/// detect a SPIR-V fallthrough edge — a case body OpBranching to another case label — so
/// the chain can be duplicated (WGSL removed `fallthrough` from the spec).
/// 32-bit selector only: targets are at words[4], words[6], ... (literal,target pairs).
/// A 64-bit selector uses 2-word literals (targets at words[5], words[9], ...) -- this
/// matches the case-label EMITTER, which also assumes 32-bit, so the two stay consistent.
fn isSwitchCaseTarget(switch_words: []const u32, lbl: u32) bool {
    if (switch_words.len >= 3 and switch_words[2] == lbl) return true; // default target
    var k: usize = 4; // words[3] = first case literal, words[4] = first case target
    while (k < switch_words.len) : (k += 2) {
        if (switch_words[k] == lbl) return true;
    }
    return false;
}

/// Advance past a pure-trampoline break arm so its OpBranch is not walked twice.
///
/// `if (cond) break;` inside a loop body lowers to a selection whose arm block holds
/// nothing but `OpBranch <loop merge>`. The BranchConditional handler emits the entire
/// `if (cond) { break; }` from the branch alone, so that block has already been fully
/// accounted for. Letting the walker reach it anyway made #loop-break-on-selection-merge
/// emit a SECOND, unconditional `break;` right after the conditional one, which made the
/// whole rest of the loop body unreachable: a plain `for` loop with an early exit
/// accumulated nothing. naga accepts unreachable code, so no validity gate saw it, and
/// the structural-drop sweep counts loops rather than reachability. 50 of 1468 corpus
/// shaders were affected -- every mandelbrot, ray-march and search-loop in the corpus.
///
/// The arm block must be IMMEDIATELY after the branch. Scanning forward for the label
/// instead would, in the `false_is_break` case, swallow the true arm that sits between
/// them. Returns the index of the arm's OpBranch, so the caller's `i += 1` lands on the
/// next block's label; returns `idx` unchanged whenever the shape is not exactly this.
fn skipBreakArm(module: *const ParsedModule, idx: usize, arm_label: u32, loop_merge: u32) usize {
    if (arm_label == loop_merge) return idx; // branch targets the merge directly: no arm block
    if (idx + 2 >= module.instructions.len) return idx;
    const lbl = module.instructions[idx + 1];
    if (lbl.op != .Label or lbl.words.len < 2 or lbl.words[1] != arm_label) return idx;
    const br = module.instructions[idx + 2];
    if (br.op != .Branch or br.words.len < 2 or br.words[1] != loop_merge) return idx;
    return idx + 2;
}

fn isPureBranchTrampoline(module: *const ParsedModule, label: u32, target: u32) bool {
    var idx: usize = 0;
    while (idx < module.instructions.len) : (idx += 1) {
        const li = module.instructions[idx];
        if (li.op == .Label and li.words.len > 1 and li.words[1] == label) {
            if (idx + 1 >= module.instructions.len) return false;
            const nx = module.instructions[idx + 1];
            return nx.op == .Branch and nx.words.len > 1 and nx.words[1] == target;
        }
    }
    return false;
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

/// The `BuiltIn` decorating member `member_idx` of struct `struct_id`, or null.
/// Unlike `getDecVal`, this reads `OpMemberDecorate` (member-level decorations are
/// not in the `decorations` map, which only collects var/id-level `OpDecorate`).
fn memberBuiltin(module: *const ParsedModule, struct_id: u32, member_idx: u32) ?spirv.BuiltIn {
    for (module.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 5) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        if (@as(spirv.Decoration, @enumFromInt(inst.words[3])) != .built_in) continue;
        return @enumFromInt(inst.words[4]);
    }
    return null;
}

/// #170: the byte `Offset` decorating member `member_idx` of struct `struct_id`
/// (`OpMemberDecorate <struct> <idx> Offset N`), or null if undecorated. Block
/// (UBO/SSBO) struct members always carry it; local/function structs never do.
fn memberOffset(module: *const ParsedModule, struct_id: u32, member_idx: u32) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 5) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        if (@as(spirv.Decoration, @enumFromInt(inst.words[3])) != .offset) continue;
        return inst.words[4];
    }
    return null;
}

/// Largest power of two dividing `n` (n>0): `n & -n`. Picks the WGSL `@align`
/// that reproduces a SPIR-V member byte Offset under WGSL's offset arithmetic —
/// roundUp(@align, prevEnd) == Offset when @align divides Offset.
fn largestPow2Divisor(n: u32) u32 {
    return n & (~n +% 1);
}

/// The `MatrixStride` decorating member `member_idx` of struct `struct_id`
/// (`OpMemberDecorate <struct> <idx> MatrixStride N`), or null if undecorated.
fn memberMatrixStride(module: *const ParsedModule, struct_id: u32, member_idx: u32) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op != .MemberDecorate or inst.words.len < 5) continue;
        if (inst.words[1] != struct_id or inst.words[2] != member_idx) continue;
        if (@as(spirv.Decoration, @enumFromInt(inst.words[3])) != .matrix_stride) continue;
        return inst.words[4];
    }
    return null;
}

/// #170: a UNIFORM member that is (or whose array element is) a 2-ROW matrix
/// (`matCx2`) is unrepresentable in core WGSL: std140 packs each column on a
/// 16-byte stride, but WGSL's `matCx2<f32>` has a fixed 8-byte column stride
/// (its column type `vec2<f32>` aligns to 8) and there is NO matrix-stride
/// attribute to override it. Emitting it anyway makes naga ACCEPT a layout that
/// reads every column past the first from the wrong byte = silent-wrong. The
/// faithful @align/@size offset pass would otherwise UNMASK this (a UBO formerly
/// rejected for a nested-member offset now validates with a mis-strided matrix),
/// so it must honest-error. Returns true when the member's MatrixStride disagrees
/// with WGSL's natural column stride (8 for 2-row, 16 for 3-/4-row). matCx3/matCx4
/// already match std140's 16-byte stride; storage (std430/scalar, MatrixStride 8)
/// also matches and is not a uniform-offset struct, so it never reaches here.
fn uniformMatrixStrideUnrepresentable(module: *const ParsedModule, struct_id: u32, member_idx: u32, member_type_id: u32) bool {
    // Unwrap EVERY array level to reach the element type — a multidimensional
    // matrix array (`mat2 m[2][3]`) is nested OpTypeArrays, and a one-level unwrap
    // would leave `t` an array and miss the matrix (silent-wrong slips through).
    // The MatrixStride decoration stays on the member regardless of nesting. Depth
    // cap mirrors the emit loop's guard against malformed cyclic SPIR-V.
    var t = member_type_id;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        const d = getDef(module, t) orelse break;
        if ((d.op == .TypeArray or d.op == .TypeRuntimeArray) and d.words.len > 2) t = d.words[2] else break;
    }
    const md = getDef(module, t) orelse return false;
    if (md.op != .TypeMatrix or md.words.len < 4) return false;
    const col = getDef(module, md.words[2]) orelse return false; // column vector type
    if (col.op != .TypeVector or col.words.len < 4) return false;
    const rows = col.words[3];
    const wgsl_col_stride: u32 = if (rows == 2) 8 else 16; // vec2 aligns to 8; vec3/vec4 to 16
    const spv_stride = memberMatrixStride(module, struct_id, member_idx) orelse return false;
    return spv_stride != wgsl_col_stride;
}

/// #170: collect (into `out`) the set of struct type ids reachable from
/// `type_id` — itself plus nested struct members, walking through array/matrix/
/// vector/pointer wrappers. Used to mark every struct reachable from a UNIFORM
/// block so the offset-attribute pass reproduces its SPIR-V member layout.
/// Depth-guarded against malformed cyclic SPIR-V; `out` doubles as the visited set.
fn collectOffsetStructsRec(module: *const ParsedModule, type_id: u32, out: *std.AutoHashMap(u32, void), depth: u32) void {
    if (depth > 16) return;
    const d = getDef(module, type_id) orelse return;
    switch (d.op) {
        .TypeStruct => {
            if (out.get(type_id) != null) return;
            out.put(type_id, {}) catch return;
            if (d.words.len <= 2) return;
            for (d.words[2..]) |mt_id| collectOffsetStructsRec(module, mt_id, out, depth + 1);
        },
        .TypePointer => if (d.words.len > 3) collectOffsetStructsRec(module, d.words[3], out, depth + 1),
        .TypeArray, .TypeRuntimeArray, .TypeMatrix, .TypeVector => if (d.words.len > 2) collectOffsetStructsRec(module, d.words[2], out, depth + 1),
        else => {},
    }
}

/// If `var_id` is an Output variable whose pointee is a struct with member 0
/// decorated `BuiltIn Position`, returns that struct type id. This is glslang's
/// `gl_PerVertex` Block: it wraps gl_Position (+ gl_PointSize/ClipDistance/
/// CullDistance) in a member-decorated struct and writes them via
/// `OpAccessChain <var> <member> + OpStore`, NOT as direct var-level-decorated
/// outputs the way zioshade's own frontend does. External-SPIR-V only.
fn perVertexBlockStructType(module: *const ParsedModule, var_id: u32) ?u32 {
    const vdef = getDef(module, var_id) orelse return null;
    if (vdef.op != .Variable or vdef.words.len < 4) return null;
    if (@as(spirv.StorageClass, @enumFromInt(vdef.words[3])) != .Output) return null;
    const ptr = getDef(module, vdef.words[1]) orelse return null;
    if (ptr.op != .TypePointer or ptr.words.len < 4) return null;
    const sty = ptr.words[3];
    const sdef = getDef(module, sty) orelse return null;
    if (sdef.op != .TypeStruct) return null;
    const bi = memberBuiltin(module, sty, 0) orelse return null;
    if (bi != .position) return null;
    return sty;
}

/// True if member `member_idx` of the gl_PerVertex block variable `var_id` is
/// WRITTEN: i.e. there is an `OpAccessChain <var_id> <const member_idx>` whose
/// result is the target of an `OpStore`. (glslang declares all four members but
/// only emits an access chain for the ones the shader actually assigns.)
fn perVertexMemberWritten(module: *const ParsedModule, var_id: u32, member_idx: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op != .AccessChain or inst.words.len < 5) continue;
        if (inst.words[3] != var_id) continue;
        const idx_def = getDef(module, inst.words[4]) orelse continue;
        if (idx_def.op != .Constant or idx_def.words.len < 4) continue;
        if (idx_def.words[3] != member_idx) continue;
        const ac_res = inst.words[2];
        for (module.instructions) |s| {
            if (s.op == .Store and s.words.len >= 2 and s.words[1] == ac_res) return true;
        }
    }
    return false;
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

fn isMatrixType(module: *const ParsedModule, type_id: u32) bool {
    const ti = common.getDef(module, type_id);
    if (ti) |inst| {
        if (inst.op == .TypeMatrix) return true;
        if (inst.op == .TypePointer and inst.words.len > 3) return isMatrixType(module, inst.words[3]);
    }
    return false;
}

fn isArrayType(module: *const ParsedModule, type_id: u32) bool {
    const ti = common.getDef(module, type_id);
    if (ti) |inst| {
        if (inst.op == .TypeArray or inst.op == .TypeRuntimeArray) return true;
        if (inst.op == .TypePointer and inst.words.len > 3) return isArrayType(module, inst.words[3]);
    }
    return false;
}

/// True when `image_type_id` resolves to an OpTypeImage flagged as a depth
/// (comparison) image — the Depth operand (word[4]) equals 1. GLSL's
/// `sampler2DShadow` and friends lower to such images. WGSL requires these to
/// be a `texture_depth_*` texture paired with a `sampler_comparison`, so both
/// resource types must follow this flag; emitting the default
/// `texture_2d<f32>` + plain `sampler` is silent-wrong (zioshade exits 0 but
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
    /// True only for an arrayed sampled texture; false otherwise so the
    /// existing (non-array) emit path is used verbatim.
    arrayed: bool,
    /// True when the OpTypeImage is a DEPTH texture (Depth=1) sampled WITHOUT a
    /// Dref (OpImageSample*/OpImageGather, not the Dref variants). WGSL's
    /// non-comparison depth forms return a SCALAR f32 and (for textureSampleLevel)
    /// take an i32 level, so the emit arms must reshape both the result and the
    /// level; see the sample arms. (#wgsl-cts)
    depth: bool = false,
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
    // A DEPTH texture sampled without a Dref still needs the arrayed coordinate
    // split (naga packs the layer into the trailing coordinate component), and
    // the sample arms additionally reshape result/level for WGSL's scalar-return
    // depth forms, so report it instead of bailing. The Dref (compare) paths
    // have their own depthCompareShape.
    const is_depth = inst.words.len > 4 and inst.words[4] == 1;
    const arrayed = inst.words[5] == 1;
    const comps: u32 = switch (inst.words[3]) {
        0 => 1, // 1D family → vec1 spatial (scalar .x)
        3 => 3, // Cube → vec3 direction
        else => 2, // 2D family → vec2 spatial
    };
    if (is_depth) return .{ .comps = comps, .arrayed = arrayed, .depth = true };
    if (!arrayed) return none;
    return .{ .comps = comps, .arrayed = true };
}

/// Shape of a STORAGE image (the operand of OpImageRead/OpImageWrite) for the
/// imageLoad/imageStore → textureLoad/textureStore lowering. `arrayed` means the
/// last coordinate component is an array layer that WGSL takes as a SEPARATE
/// argument (`textureLoad(t, coord.xy, coord.z)`), not part of the coordinate.
/// `ms` (multisampled storage, image2DMS) has NO WGSL representation — there is
/// no multisampled storage texture type — so callers honest-error on it.
const StorageImageShape = struct { arrayed: bool, ms: bool, spatial: u32 };
fn storageImageShape(module: *const ParsedModule, image_value_id: u32) StorageImageShape {
    const none = StorageImageShape{ .arrayed = false, .ms = false, .spatial = 2 };
    // No OpTypeSampledImage unwrap step (unlike depthCompareShape/arrayedSampleShape):
    // storage images are never combined-sampler types, so the pointee is the TypeImage.
    const type_id = getTypeOf(module, image_value_id) orelse return none;
    var inst = getDef(module, type_id) orelse return none;
    if (inst.op == .TypePointer and inst.words.len > 3) {
        inst = getDef(module, inst.words[3]) orelse return none;
    }
    if (inst.op != .TypeImage or inst.words.len <= 6) return none;
    // OpTypeImage: [op, result, sampled_type, Dim, Depth, Arrayed, MS, Sampled, Format]
    const spatial: u32 = switch (inst.words[3]) {
        0 => 1, // 1D
        2 => 3, // 3D (never arrayed)
        else => 2, // 2D family
    };
    return .{ .arrayed = inst.words[5] == 1, .ms = inst.words[6] == 1, .spatial = spatial };
}

/// SPIR-V `Dim` operand of the image behind an image VALUE id (an OpLoad result,
/// the operand of OpImageRead). Resolves the value's result type and unwraps an
/// OpTypeSampledImage, mirroring the MSL backend's imageValueDim. Returns 1 (2D)
/// when it cannot be resolved, matching this backend's 2D default. Dim 6 is
/// SubpassData (Vulkan input attachments). OpTypeImage layout:
/// [op, result, sampled_type, DIM, Depth, Arrayed, MS, ...].
fn imageValueDim(module: *const ParsedModule, image_value_id: u32) u32 {
    const vdef = getDef(module, image_value_id) orelse return 1;
    if (vdef.words.len < 2) return 1;
    var tinst = getDef(module, vdef.words[1]) orelse return 1;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(module, tinst.words[2]) orelse return 1;
    }
    if (tinst.op != .TypeImage or tinst.words.len < 4) return 1;
    return tinst.words[3];
}

/// Unwrap every TypeArray / TypeRuntimeArray level of `type_id`, returning the id
/// of the innermost (non-array) element type. A non-array type is returned
/// unchanged. Used to reach the block STRUCT behind an `array<Block, N>` pointee:
/// glslang's legacy SPIR-V puts the `BufferBlock` decoration on the struct, not on
/// the array, so an array-of-SSBO variable must unwrap to the element struct
/// before the decoration check — otherwise it is mis-classified as a read-only
/// uniform and a store is silently rejected by naga. (#170)
///
/// `depth` caps the walk: valid SPIR-V types form an acyclic DAG so real array
/// nesting is 1–2 levels deep, but a malformed/hostile module could encode a
/// self-referential array type. The cap degrades that gracefully (returns the
/// last array id → callers treat it as a non-struct, no honest behavior change)
/// rather than hanging, matching the depth-guarded type walks elsewhere here.
fn arrayElementType(module: *const ParsedModule, type_id: u32) u32 {
    var tid = type_id;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        const d = getDef(module, tid) orelse break;
        if ((d.op == .TypeArray or d.op == .TypeRuntimeArray) and d.words.len >= 3) {
            tid = d.words[2];
        } else break;
    }
    return tid;
}

/// True if `type_id` is an ARRAY (fixed or runtime) whose element struct contains
/// a RUNTIME-sized array member — e.g. an array of SSBO blocks
/// (`buffer SSBO { vec4 data[]; } ssbos[2];` → `array<SSBO, 2>` where SSBO has
/// `data: array<vec4f>`). WGSL forbids a runtime-sized array nested inside a
/// fixed-size array (naga: "Base type for the array is invalid"), and there is no
/// core-WGSL way to express a dynamically-indexed array of runtime-sized storage
/// buffers (would need per-element separate bindings + static indices). So the
/// WGSL backend honest-errors rather than emit the naga-rejected nesting.
fn ssboArrayOfRuntimeArrayStruct(module: *const ParsedModule, type_id: u32) bool {
    const head = getDef(module, type_id) orelse return false;
    if (head.op != .TypeArray and head.op != .TypeRuntimeArray) return false;
    // Unwrap every array level to the element type (shared primitive, so the
    // depth cap / cycle guard lives in one place).
    const el = getDef(module, arrayElementType(module, type_id)) orelse return false;
    if (el.op != .TypeStruct) return false;
    for (el.words[2..]) |member_type_id| {
        const m = getDef(module, member_type_id) orelse continue;
        if (m.op == .TypeRuntimeArray) return true;
    }
    return false;
}

/// True if the texture behind a sampled-image value id has an INTEGER sampled
/// component type (GLSL isampler*/usampler* → `texture_2d<i32>`/`<u32>`). WGSL
/// integer textures are non-filterable: only `textureLoad` is allowed, NOT the
/// filtering `textureSample`/`textureSampleLevel`/`textureSampleGrad` builtins.
/// A GLSL `texture(isampler2D, …)` (normalized-coord sample) thus has no faithful
/// WGSL form — emitting textureSample is a naga reject (silent-wrong) → honest-error.
/// `texelFetch` is unaffected (it lowers to textureLoad). OpTypeImage layout:
/// [op, result_id, sampled_type, dim, depth, arrayed, ms, sampled, format]. (#170)
fn isIntegerSampledImage(module: *const ParsedModule, sampled_image_value_id: u32) bool {
    const type_id = getTypeOf(module, sampled_image_value_id) orelse return false;
    var inst = getDef(module, type_id) orelse return false;
    if (inst.op == .TypePointer and inst.words.len > 3) inst = getDef(module, inst.words[3]) orelse return false;
    if (inst.op == .TypeSampledImage and inst.words.len > 2) inst = getDef(module, inst.words[2]) orelse return false;
    if (inst.op != .TypeImage or inst.words.len <= 2) return false;
    const comp = getDef(module, inst.words[2]) orelse return false;
    return comp.op == .TypeInt;
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

const ImageQueryShape = struct { arrayed: bool, spatial: u32, storage: bool = false };
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
    // OpTypeImage Sampled operand: 2 = storage-only image (WGSL texture_storage_*).
    // WGSL's textureDimensions has NO level overload for storage textures, but
    // naga emits OpImageQuerySizeLod (lod 0) for them anyway, so the lod must be
    // dropped at emission. (#wgsl-cts)
    const storage = inst.words.len > 7 and inst.words[7] == 2;
    return .{ .arrayed = inst.words[5] == 1, .spatial = spatial, .storage = storage };
}

/// The signed WGSL vector/scalar type alias for `n` integer components
/// (1→"i32", 2→"vec2i", 3→"vec3i"), used to convert an unsigned
/// `textureDimensions` result to the signed GLSL query type.
fn signedIntVecType(n: u32) []const u8 {
    return intVecTypeFor(n, true);
}

/// The integer vector/scalar alias for `n` components with the given
/// signedness (1 is "i32"/"u32", 2 is "vec2i"/"vec2u", 3 is "vec3i"/"vec3u").
/// Used to wrap a `textureDimensions` result (always unsigned) into the SPIR-V
/// query's OWN result signedness: glslang queries are ivecN, but naga's WGSL
/// producers declare uvecN results, and wrapping those in the signed alias made
/// the outer constructor mix component types (naga: "Composing 0's component
/// type is not expected"). (#wgsl-cts)
fn intVecTypeFor(n: u32, signed: bool) []const u8 {
    if (signed) {
        return switch (n) {
            1 => "i32",
            3 => "vec3i",
            else => "vec2i",
        };
    }
    return switch (n) {
        1 => "u32",
        3 => "vec3u",
        else => "vec2u",
    };
}

/// Whether an integer scalar/vector type id is UNSIGNED (u32/vecNu). Defaults
/// to signed (the GLSL query shape) when the type cannot be resolved.
fn intTypeIsUnsigned(module: *const ParsedModule, type_id: u32) bool {
    var t = getDef(module, type_id) orelse return false;
    if (t.op == .TypeVector) {
        if (t.words.len > 2) {
            t = getDef(module, t.words[2]) orelse return false;
        } else return false;
    }
    if (t.op != .TypeInt) return false;
    return !(t.words.len > 3 and t.words[3] == 1);
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
/// `builtin` is "textureSampleCompare" or "textureSampleCompareLevel"; the
/// caller picks. CompareLevel is used for the EXPLICIT form (WGSL drops the
/// SPIR-V Lod operand, always sampling mip 0) AND for an implicit form the
/// uniformity prepass marked as sitting in non-uniform control flow, where
/// textureSampleCompare is a tint reject and CompareLevel is the ungated
/// spelling (#wgsl-uniformity-8k2).
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
    // The sampled image may be a COMBINED sampler2DShadow global (tex_name is
    // its own name; the `<tex>_sampler` partner carries the sampler_comparison
    // type) or an OpSampledImage built AT THE CALL SITE from a separate depth
    // texture + comparison sampler (naga/tint's only shape): then the texture
    // is the sampled image's image operand and the sampler is its sampler
    // operand (see resolveSamplerArg).
    var tex_name: []const u8 = names.get(inst.words[3]) orelse "tex";
    if (getDef(module, inst.words[3])) |sii| {
        if (sii.op == .SampledImage and sii.words.len > 3) {
            tex_name = names.get(sii.words[2]) orelse tex_name;
        }
    }
    const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
    const coord = names.get(inst.words[4]) orelse "uv";
    const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
    const shape = depthCompareShape(module, inst.words[3]);
    const coord_swz: []const u8 = if (shape.comps == 3) ".xyz" else ".xy";
    // Image-operand gate (Dref=words[5], mask=words[6], values from words[7];
    // operands follow ascending bit order Bias 0x1, Lod 0x2, Grad 0x4,
    // ConstOffset 0x8). WGSL's depth-compare builtins carry ONLY a const-offset
    // argument: textureSampleCompare takes no bias, and textureSampleCompareLevel
    // has NO explicit level (naga lowers it to OpImageSampleDrefExplicitLod with
    // Lod = literal 0). Silently DROPPING a non-zero Lod or any Bias therefore
    // samples the wrong mip; naga still validates the output, so it is the
    // silent-wrong this backend forbids. Lower only the faithful forms:
    //   - implicit: at most a ConstOffset (a Bias is refused);
    //   - explicit: a Lod that is the constant 0 plus at most a ConstOffset.
    const is_explicit = inst.op == .ImageSampleDrefExplicitLod;
    var off_suffix: []const u8 = "";
    const dmask: u32 = if (inst.words.len > 6) inst.words[6] else 0;
    {
        const allowed: u32 = 0x8 | (if (is_explicit) @as(u32, 0x2) else 0);
        if (dmask & ~allowed != 0) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL depth-compare builtins have no bias/grad operand and no explicit level (textureSampleCompareLevel samples level 0)", .{}) catch null;
            return error.UnsupportedImageOperands;
        }
        if (is_explicit and dmask & 0x2 != 0) {
            // The Lod operand sits first (bit 0x2 precedes ConstOffset 0x8).
            const lod_id = inst.words[7];
            const lod_const = getDef(module, lod_id);
            const lod_is_zero = if (lod_const) |lc| (lc.op == .Constant and lc.words.len > 3 and lc.words[3] == 0) else false;
            if (!lod_is_zero) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL textureSampleCompareLevel samples level 0 and takes no level argument; an OpImageSampleDrefExplicitLod with a non-zero Lod has no faithful WGSL form", .{}) catch null;
                return error.UnsupportedImageOperands;
            }
        }
        if (dmask & 0x8 != 0) {
            // WGSL textureSampleCompare(Level)'s const-offset arg exists for the
            // 2D family INCLUDING texture_depth_2d_array, but NOT for
            // cube/cube_array -> honest-error on cube rather than emit a builtin
            // naga rejects. (#170; the 2d_array refusal was over-broad and
            // refused valid offset forms.)
            if (shape.comps == 3) return error.UnsupportedImageOperands;
            var ow: usize = 7;
            if (dmask & 0x2 != 0) ow += 1; // Lod
            if (ow >= inst.words.len) return error.UnsupportedImageOperands;
            off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[ow]) orelse "vec2<i32>(0)"});
        }
    }
    try writeIndentStatic(w, indent);
    if (shape.arrayed) {
        const layer_comp: []const u8 = if (shape.comps == 3) ".w" else ".z";
        try w.print("let {s}: {s} = {s}({s}, {s}, {s}{s}, i32(round({s}{s})), {s}{s});\n", .{ result_name, rt, builtin, tex_name, sampler_arg, coord, coord_swz, coord, layer_comp, dref, off_suffix });
    } else {
        try w.print("let {s}: {s} = {s}({s}, {s}, {s}{s}, {s}{s});\n", .{ result_name, rt, builtin, tex_name, sampler_arg, coord, coord_swz, dref, off_suffix });
    }
}

// Strict WGSL keywords + reserved words from https://www.w3.org/TR/WGSL/#reserved-words
// plus the commonly-emitted predeclared type / address-space names that
// callers also can't legally use as identifiers. Reserved words include `ref`,
// which is what the GL_EXT_buffer_reference fixture trips over.
const wgsl_reserved_words = std.StaticStringMap(void).initComptime(.{
    // Keywords (§ Keyword Summary)
    .{ "alias", {} },                    .{ "break", {} },                         .{ "case", {} },
    .{ "const", {} },                    .{ "const_assert", {} },                  .{ "continue", {} },
    .{ "continuing", {} },               .{ "default", {} },                       .{ "diagnostic", {} },
    .{ "discard", {} },                  .{ "else", {} },                          .{ "enable", {} },
    .{ "false", {} },                    .{ "fn", {} },                            .{ "for", {} },
    .{ "if", {} },                       .{ "let", {} },                           .{ "loop", {} },
    .{ "override", {} },                 .{ "requires", {} },                      .{ "return", {} },
    .{ "struct", {} },                   .{ "switch", {} },                        .{ "true", {} },
    .{ "var", {} },                      .{ "while", {} },
    // Reserved words (§ Reserved Words)
                            .{ "NULL", {} },
    .{ "Self", {} },                     .{ "abstract", {} },                      .{ "active", {} },
    .{ "alignas", {} },                  .{ "alignof", {} },                       .{ "as", {} },
    .{ "asm", {} },                      .{ "asm_fragment", {} },                  .{ "async", {} },
    .{ "attribute", {} },                .{ "auto", {} },                          .{ "await", {} },
    .{ "become", {} },                   .{ "binding_array", {} },                 .{ "cast", {} },
    .{ "catch", {} },                    .{ "class", {} },                         .{ "co_await", {} },
    .{ "co_return", {} },                .{ "co_yield", {} },                      .{ "coherent", {} },
    .{ "column_major", {} },             .{ "common", {} },                        .{ "compile", {} },
    .{ "compile_fragment", {} },         .{ "concept", {} },                       .{ "const_cast", {} },
    .{ "consteval", {} },                .{ "constexpr", {} },                     .{ "constinit", {} },
    .{ "crate", {} },                    .{ "debugger", {} },                      .{ "decltype", {} },
    .{ "delete", {} },                   .{ "demote", {} },                        .{ "demote_to_helper", {} },
    .{ "do", {} },                       .{ "dynamic_cast", {} },                  .{ "enum", {} },
    .{ "explicit", {} },                 .{ "export", {} },                        .{ "extends", {} },
    .{ "extern", {} },                   .{ "external", {} },                      .{ "fallthrough", {} },
    .{ "filter", {} },                   .{ "final", {} },                         .{ "finally", {} },
    .{ "friend", {} },                   .{ "from", {} },                          .{ "fxgroup", {} },
    .{ "get", {} },                      .{ "goto", {} },                          .{ "groupshared", {} },
    .{ "highp", {} },                    .{ "impl", {} },                          .{ "implements", {} },
    .{ "import", {} },                   .{ "inline", {} },                        .{ "instanceof", {} },
    .{ "interface", {} },                .{ "layout", {} },                        .{ "lowp", {} },
    .{ "macro", {} },                    .{ "macro_rules", {} },                   .{ "match", {} },
    .{ "mediump", {} },                  .{ "meta", {} },                          .{ "mod", {} },
    .{ "module", {} },                   .{ "move", {} },                          .{ "mut", {} },
    .{ "mutable", {} },                  .{ "namespace", {} },                     .{ "new", {} },
    .{ "nil", {} },                      .{ "noexcept", {} },                      .{ "noinline", {} },
    .{ "nointerpolation", {} },          .{ "non_coherent", {} },                  .{ "noncoherent", {} },
    .{ "noperspective", {} },            .{ "null", {} },                          .{ "nullptr", {} },
    .{ "of", {} },                       .{ "operator", {} },                      .{ "package", {} },
    .{ "packoffset", {} },               .{ "partition", {} },                     .{ "pass", {} },
    .{ "patch", {} },                    .{ "pixelfragment", {} },                 .{ "precise", {} },
    .{ "precision", {} },                .{ "premerge", {} },                      .{ "priv", {} },
    .{ "protected", {} },                .{ "pub", {} },                           .{ "public", {} },
    .{ "readonly", {} },                 .{ "ref", {} },                           .{ "regardless", {} },
    .{ "register", {} },                 .{ "reinterpret_cast", {} },              .{ "require", {} },
    .{ "resource", {} },                 .{ "restrict", {} },                      .{ "self", {} },
    .{ "set", {} },                      .{ "shared", {} },                        .{ "sizeof", {} },
    .{ "smooth", {} },                   .{ "snorm", {} },                         .{ "static", {} },
    .{ "static_assert", {} },            .{ "static_cast", {} },                   .{ "std", {} },
    .{ "subroutine", {} },               .{ "super", {} },                         .{ "target", {} },
    .{ "template", {} },                 .{ "this", {} },                          .{ "thread_local", {} },
    .{ "throw", {} },                    .{ "trait", {} },                         .{ "try", {} },
    .{ "type", {} },                     .{ "typedef", {} },                       .{ "typeid", {} },
    .{ "typename", {} },                 .{ "typeof", {} },                        .{ "union", {} },
    .{ "unless", {} },                   .{ "unorm", {} },                         .{ "unsafe", {} },
    .{ "unsized", {} },                  .{ "use", {} },                           .{ "using", {} },
    .{ "varying", {} },                  .{ "virtual", {} },                       .{ "volatile", {} },
    .{ "wgsl", {} },                     .{ "where", {} },                         .{ "with", {} },
    .{ "writeonly", {} },                .{ "yield", {} },
    // Predeclared scalar / address-space / type names that are also illegal
    // as identifiers — kept from the previous (pre-spec) list for back-compat.
                            .{ "array", {} },
    .{ "atomic", {} },                   .{ "bool", {} },                          .{ "f16", {} },
    .{ "f32", {} },                      .{ "function", {} },                      .{ "i32", {} },
    .{ "mat2x2", {} },                   .{ "mat2x3", {} },                        .{ "mat2x4", {} },
    .{ "mat3x2", {} },                   .{ "mat3x3", {} },                        .{ "mat3x4", {} },
    .{ "mat4x2", {} },                   .{ "mat4x3", {} },                        .{ "mat4x4", {} },
    .{ "private", {} },                  .{ "ptr", {} },                           .{ "storage", {} },
    .{ "u32", {} },                      .{ "uniform", {} },                       .{ "vec2", {} },
    .{ "vec3", {} },                     .{ "vec4", {} },                          .{ "workgroup", {} },
    // Predeclared texture / sampler types (§ Texture Types, § Sampler Types).
    // Not strictly reserved by the spec, but shadowing them produces output
    // that confuses naga's diagnostics and may break under future revisions.
    .{ "sampler", {} },                  .{ "sampler_comparison", {} },            .{ "texture_1d", {} },
    .{ "texture_2d", {} },               .{ "texture_2d_array", {} },              .{ "texture_3d", {} },
    .{ "texture_cube", {} },             .{ "texture_cube_array", {} },            .{ "texture_multisampled_2d", {} },
    .{ "texture_depth_2d", {} },         .{ "texture_depth_2d_array", {} },        .{ "texture_depth_cube", {} },
    .{ "texture_depth_cube_array", {} }, .{ "texture_depth_multisampled_2d", {} }, .{ "texture_storage_1d", {} },
    .{ "texture_storage_2d", {} },       .{ "texture_storage_2d_array", {} },      .{ "texture_storage_3d", {} },
    .{ "texture_external", {} },
    // Predeclared builtin FUNCTION names that zioshade EMITS as calls AND that are
    // ALSO legal GLSL identifiers — i.e. WGSL builtins whose GLSL counterpart has
    // a DIFFERENT name, so a GLSL variable can legally be named the WGSL one
    // (`bitcast`←floatBitsToInt, `select`←OpSelect, `dpdx`←dFdx, `countOneBits`←
    // bitCount, `reverseBits`←bitfieldReverse, `extractBits`←bitfieldExtract,
    // `firstLeadingBit`←findMSB, `pack2x16float`←packHalf2x16, `arrayLength`←
    // `.length()`, …). A shadowing variable makes naga reject the builtin call
    // ("local declaration cannot be called") = silent-wrong. The builtin call
    // text is emitted as a fixed string, NOT via the name map, so renaming the
    // colliding user identifier (→ `name_`) leaves the call intact. (Most other
    // WGSL builtins — min/max/dot/mix/… — are ALSO GLSL builtins, so they can't
    // be GLSL identifiers and need no entry.) (#170)
            .{ "bitcast", {} },                       .{ "select", {} },
    .{ "dpdx", {} },                     .{ "dpdy", {} },                          .{ "dpdxCoarse", {} },
    .{ "dpdxFine", {} },                 .{ "dpdyCoarse", {} },                    .{ "dpdyFine", {} },
    // fwidth's Fine/Coarse variants are NOT GLSL builtins, so a GLSL local may
    // legally hold those names and shadow the emitted builtin (#685 review).
    // Plain fwidth IS a GLSL builtin and needs no entry.
    .{ "fwidthCoarse", {} },             .{ "fwidthFine", {} },                    .{ "quantizeToF16", {} },
    .{ "arrayLength", {} },              .{ "countOneBits", {} },                  .{ "reverseBits", {} },
    .{ "extractBits", {} },              .{ "insertBits", {} },                    .{ "firstLeadingBit", {} },
    .{ "firstTrailingBit", {} },         .{ "pack2x16float", {} },                 .{ "pack2x16snorm", {} },
    .{ "pack2x16unorm", {} },            .{ "pack4x8snorm", {} },                  .{ "pack4x8unorm", {} },
    .{ "unpack2x16float", {} },          .{ "unpack2x16snorm", {} },               .{ "unpack2x16unorm", {} },
    .{ "unpack4x8snorm", {} },           .{ "unpack4x8unorm", {} },
    // WGSL texture builtin functions. Their GLSL counterparts have DIFFERENT
    // names (texture→textureSample, texelFetch→textureLoad, textureSize→
    // textureDimensions, imageStore→textureStore, textureQueryLevels→
    // textureNumLevels, textureSamples→textureNumSamples), so the WGSL names are
    // legal GLSL identifiers and a colliding GLSL var would shadow the emitted
    // call. (textureGather IS also a GLSL builtin so can't be a GLSL var — listed
    // for completeness; the entry is harmless.) Same class as bitcast/select.
    // textureSampleBias / textureSampleBaseClampToEdge are reserved PROACTIVELY —
    // zioshade does not emit them yet (the ImageSample Bias/MinLod operands are not
    // currently lowered), but reserving a real WGSL builtin name is always safe. (#170)
                   .{ "textureSample", {} },
    .{ "textureSampleBias", {} },        .{ "textureSampleLevel", {} },            .{ "textureSampleGrad", {} },
    .{ "textureSampleCompare", {} },     .{ "textureSampleCompareLevel", {} },     .{ "textureSampleBaseClampToEdge", {} },
    .{ "textureGather", {} },            .{ "textureGatherCompare", {} },          .{ "textureLoad", {} },
    .{ "textureStore", {} },             .{ "textureDimensions", {} },             .{ "textureNumLayers", {} },
    .{ "textureNumLevels", {} },         .{ "textureNumSamples", {} },
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

fn emitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap, wrapped_members: *const WrappedUniformMemberMap, offset_structs: *const std.AutoHashMap(u32, void)) !void {
    const inst = getDef(module, root_type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            try emitOneStructForwardDecl(module, names, root_type_id, w, alloc, emitted, emitted_names, atomic_fields, wrapped_members, offset_structs);
        },
        .TypePointer => if (inst.words.len > 3) try emitStructForwardDecls(module, names, inst.words[3], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members, offset_structs),
        .TypeArray => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members, offset_structs),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names, atomic_fields, wrapped_members, offset_structs),
        else => {},
    }
}

fn emitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void), atomic_fields: *const AtomicFieldMap, wrapped_members: *const WrappedUniformMemberMap, offset_structs: *const std.AutoHashMap(u32, void)) !void {
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
                        try emitOneStructForwardDecl(module, names, cur_id, w, alloc, emitted, emitted_names, atomic_fields, wrapped_members, offset_structs);
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

    // #170: a UNIFORM-reachable block struct must reproduce its SPIR-V member byte
    // offsets in WGSL — the uniform address space requires struct/array members at
    // 16-byte boundaries, which std140 already provides but the attribute-less WGSL
    // hid, so naga recomputed sub-16 offsets and rejected. `want_offsets` gates the
    // per-member @align/@size emission below; non-uniform structs stay byte-identical.
    const want_offsets = offset_structs.get(type_id) != null;
    if (want_offsets and inst.words.len > 2) {
        // WGSL always places the first struct member at offset 0; a uniform block
        // whose member 0 sits at a non-zero offset would need a synthetic leading
        // pad member to reproduce. zioshade's frontend packs member 0 at 0 (std140),
        // so this is a defensive honest-error guarding against a future silent-wrong.
        if (memberOffset(module, type_id, 0)) |o0| {
            if (o0 != 0) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot reproduce a uniform block whose first member is at byte offset {d} (a non-zero leading offset needs a synthetic pad member)", .{o0}) catch null;
                return error.UnsupportedOp;
            }
        }
        // A 2-row matrix (matCx2) member is unrepresentable in a WGSL uniform: its
        // std140 16-byte column stride cannot be expressed (WGSL matCx2 is fixed at
        // 8). Honest-error BEFORE any struct text is written, rather than let the
        // offset pass UNMASK a silently-wrong matrix (see helper). Pre-scanned here
        // so the failure is loud and clean (no half-emitted struct).
        for (inst.words[2..], 0..) |mt_id, mi| {
            if (uniformMatrixStrideUnrepresentable(module, type_id, @intCast(mi), mt_id)) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot express a 2-row matrix (matCx2) in a uniform block: std140's 16-byte column stride has no WGSL equivalent (matCx2 column stride is fixed at 8)", .{}) catch null;
                return error.UnsupportedOp;
            }
        }
    }

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

        // #170: faithful UNIFORM member layout. `@align` pins this member's start to
        // its SPIR-V byte Offset (min(largestPow2Divisor(off), 16) always divides
        // off and never exceeds std140's max alignment); `@size` pads it out to the
        // NEXT member's offset so the following member is placed correctly regardless
        // of this member's WGSL-natural size (a nested struct or matrix is smaller in
        // WGSL than under std140). Both derive purely from the Offset decorations, so
        // the WGSL layout matches the host's std140 packing. Empty for non-uniform.
        var attrs: []const u8 = "";
        if (want_offsets) {
            if (memberOffset(module, type_id, @intCast(mi))) |off| {
                const member_count = inst.words.len - 2;
                const a: u32 = if (off == 0) 0 else @min(largestPow2Divisor(off), @as(u32, 16));
                var nsize: u32 = 0;
                if (mi + 1 < member_count) {
                    if (memberOffset(module, type_id, @intCast(mi + 1))) |noff| {
                        if (noff > off) nsize = noff - off;
                    }
                }
                if (a != 0 and nsize != 0) {
                    attrs = try std.fmt.allocPrint(alloc, "@align({d}) @size({d}) ", .{ a, nsize });
                } else if (a != 0) {
                    attrs = try std.fmt.allocPrint(alloc, "@align({d}) ", .{a});
                } else if (nsize != 0) {
                    attrs = try std.fmt.allocPrint(alloc, "@size({d}) ", .{nsize});
                }
            }
        }

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
                    try w.print("    {s}{s}: array<vec4<{s}>, {d}>,\n", .{ attrs, mname, vbase, lv });
                    continue;
                }
                const et = try wgslType(module, mi2.words[2], names, alloc);
                if (atomic_kind == .array_element) {
                    try w.print("    {s}{s}: array<atomic<{s}>, {d}>,\n", .{ attrs, mname, et, lv });
                } else {
                    try w.print("    {s}{s}: array<{s}, {d}>,\n", .{ attrs, mname, et, lv });
                }
                continue;
            }
            if (mi2.op == .TypeRuntimeArray and mi2.words.len > 2 and atomic_kind == .array_element) {
                const et = try wgslType(module, mi2.words[2], names, alloc);
                try w.print("    {s}{s}: array<atomic<{s}>>,\n", .{ attrs, mname, et });
                continue;
            }
        }
        const mt = try wgslType(module, mt_id, names, alloc);
        if (atomic_kind == .scalar) {
            try w.print("    {s}{s}: atomic<{s}>,\n", .{ attrs, mname, mt });
        } else {
            try w.print("    {s}{s}: {s},\n", .{ attrs, mname, mt });
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

/// Emit the statement that a discarded switch case-body terminator stands for.
///
/// Both case-body walkers emit their region by walking instructions and stopping at the
/// first terminator, which they then discard. Two of the four things that terminator can
/// be are genuinely nothing to emit: a branch to a nested selection's own merge (control
/// just falls out of the `if`), and a branch to the switch's merge FROM THE CASE BODY
/// ITSELF (WGSL cases do not fall through, so the break is implicit). The other two are
/// not:
///
///   the SWITCH's merge, reached from inside a nested selection -> `break;`
///   the enclosing LOOP's continue target                       -> `continue;`
///
/// Dropping the first is #581: graphicsfuzz_081 emitted `if v36 { }` where MSL emits
/// `if (v38) { break; }`, so the statements after the `if` ran on a path that should have
/// exited. Dropping the second is #switch-case-continue: the code after the switch runs on
/// a path that should have gone straight to the `continuing` block. GLSL (#584), MSL (#586)
/// and HLSL (#587) all emit the continue; WGSL was the last backend still dropping it.
/// Both are silent-wrong -- naga accepts the output either way.
///
/// `implicit_break` distinguishes the two call shapes: true at the two
/// top-level case-body sites, where reaching the switch's merge is the
/// ordinary end of the case and needs no `break;` (WGSL cases do not fall
/// through); false at the nested-selection arms, where falling out of an
/// `if` straight to the switch's merge must emit `break;`. Targets outside
/// {merge, extra_legit, loop_continue} refuse with
/// UnsupportedSwitchCaseExit — the walk cannot follow them without silently
/// truncating the case (#wgsl-switch-case-exit).
/// #wgsl-region-mode: is `label` the header of a LOOP block (its block holds
/// an OpLoopMerge before its terminator)? Returns the index of the Label so
/// the caller can hand [header..] to the real walker.
fn labelIsLoopHeader(module: *const ParsedModule, label: u32) ?usize {
    for (module.instructions, 0..) |inst, li| {
        if (inst.op == .Label and inst.words.len > 1 and inst.words[1] == label) {
            var k = li + 1;
            while (k < module.instructions.len) : (k += 1) {
                const t = module.instructions[k];
                if (t.op == .LoopMerge) return li;
                if (t.op == .Label or t.op == .Branch or t.op == .BranchConditional or
                    t.op == .Switch or t.op == .Return or t.op == .ReturnValue or t.op == .Kill) return null;
            }
            return null;
        }
    }
    return null;
}

/// #wgsl-loop-merge-phi: assignments for a LOOP-EXIT BranchConditional to the
/// merge block -- the merge phis' values on this path. Emitted inside the
/// inverted-test break: `if (!(cond)) { vN = X; break; }`. Empty when this
/// exit has no merge phis (the common case -- returns the input break text).
fn loopExitPhiAssignments(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    ctx: *WalkCtx,
    idx: usize,
    func_idx: usize,
    merge_label: u32,
    arena: std.mem.Allocator,
    eff_pred: ?u32,
) ![]const u8 {
    const phi_list = ctx.sel_phis.get(merge_label) orelse return "";
    // Current predecessor: the Label of the block containing the branch at idx.
    var cur_pred: ?u32 = null;
    var li: usize = if (idx > 0) idx - 1 else 0;
    while (li > func_idx) : (li -= 1) {
        if (module.instructions[li].op == .Label and module.instructions[li].words.len > 1) {
            cur_pred = module.instructions[li].words[1];
            break;
        }
    }
    // A trampoline-folded break (cond -> pure block -> merge) must use the
    // TRAMPOLINE's label as the predecessor -- that is the phi's incoming pred.
    const cp = eff_pred orelse (cur_pred orelse return "");
    var buf = std.ArrayList(u8).empty;
    for (phi_list.items) |sp| {
        if (sp.pred_label != cp) continue;
        const rn = names.get(sp.result_id) orelse continue;
        const vn = names.get(sp.value_id) orelse continue;
        try buf.print(arena, "{s} = {s}; ", .{ rn, vn });
    }
    return buf.items;
}

fn emitSwitchArmTerminator(
    module: *const ParsedModule,
    idx: usize,
    switch_merge: u32,
    implicit_break: bool,
    extra_legit: []const u32,
    loop_continue: ?u32,
    w: anytype,
    depth: u32,
) !void {
    if (idx >= module.instructions.len) return;
    const term = module.instructions[idx];
    if (term.op != .Branch or term.words.len < 2) return;
    const target = term.words[1];
    if (loop_continue) |lc| {
        if (target == lc) {
            try writeIndentStatic(w, depth);
            try w.writeAll("continue;\n");
            return;
        }
    }
    if (target == switch_merge) {
        // The ordinary end of a case needs no `break;` in WGSL (cases do not
        // fall through) -- implicit at the arm-walk level, explicit (`break;`)
        // when a nested construct exits the switch mid-body.
        if (!implicit_break) {
            try writeIndentStatic(w, depth);
            try w.writeAll("break;\n");
        }
        return;
    }
    for (extra_legit) |l| {
        if (l == target) return; // falls out of a nested if / fallthrough into another case: no statement
    }
    return recordUnsupportedSwitchCaseExit(target);
}

fn wgslType(module: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, type_id) orelse {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: unresolved type id {d}", .{type_id}) catch null;
        return error.UnsupportedOp;
    };
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
                // SubpassData (Dim 6) is read-only at the fragment position: use
                // `read` (read_write is rejected by naga in fragment stage). The
                // binding site forces the same mode; this guards the no-variable
                // path. (Port of MSL #488.)
                const fallback_mode: []const u8 = if (dim == 6) "read" else "read_write";
                break :blk try wgslStorageTextureType(module, type_id, fallback_mode, alloc);
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
        else => {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: unsupported type opcode '{s}'", .{@tagName(inst.op)}) catch null;
            return error.UnsupportedOp;
        },
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
    const inst = getDef(module, image_type_id) orelse {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: unresolved storage-texture image type id {d}", .{image_type_id}) catch null;
        return error.UnsupportedOp;
    };
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
        "vec2i", "vec3i",
        "vec4i", "vec2u",
        "vec3u", "vec4u",
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

/// The WGSL zero-value literal for a SPIR-V type: `0`/`0u` (int), `0.0` (float),
/// `false` (bool), `T()` (vector/matrix/struct/array, where WGSL's value
/// constructor with no components is the zero value). Null when the type has no
/// WGSL value literal (pointer, image, sampler, sampled image): callers leave
/// those ids on their generic name rather than invent a value. Caller owns the
/// result.
fn zeroLiteralOfType(module: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ?[]const u8 {
    const ti = getDef(module, type_id) orelse return null;
    return switch (ti.op) {
        .TypeInt => if (ti.words.len > 3 and ti.words[3] == 1)
            std.fmt.allocPrint(alloc, "0", .{}) catch null
        else
            std.fmt.allocPrint(alloc, "0u", .{}) catch null,
        .TypeFloat => std.fmt.allocPrint(alloc, "0.0", .{}) catch null,
        .TypeBool => std.fmt.allocPrint(alloc, "false", .{}) catch null,
        .TypeVector, .TypeMatrix, .TypeStruct, .TypeArray, .TypeRuntimeArray => blk: {
            const tn = wgslType(module, type_id, names, alloc) catch break :blk null;
            break :blk std.fmt.allocPrint(alloc, "{s}()", .{tn}) catch null;
        },
        else => null,
    };
}

fn collectNames(alloc: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    common.collectNames(alloc, module, names);

    // OpUndef (module-scope, per SPIR-V spec) is named by common.collectNames but
    // every emit switch only visits module-scope OpVariable, so it was referenced at
    // use sites with no declaration -> undeclared identifier. Fold it to a zero
    // literal inline (the other backends fold the semantically identical OpConstantNull;
    // WGSL has no ConstantNull fold, so this is its own block). The in-body `.Undef =>`
    // arm is a no-op; the value is inlined here. Matches spirv-cross (zero-inits undef).
    for (module.instructions) |inst| {
        if (inst.op != .Undef or inst.words.len <= 2) continue;
        const z: ?[]const u8 = zeroLiteralOfType(module, inst.words[1], names, alloc);
        const lit = z orelse std.fmt.allocPrint(alloc, "0", .{}) catch continue;
        if (names.fetchPut(inst.words[2], lit) catch null) |old| alloc.free(old.value);
    }

    // OpConstantNull: common.collectNames has no literal branch for it, so every
    // null id falls through to the generic `v{N}` counter name, and since no
    // emit switch ever declares that name, ANY use site referencing it produced
    // an undeclared identifier at exit 0 (silent-wrong; naga rejects). naga's
    // WGSL front end emits OpConstantNull for every plain `var x: T;` (as the
    // OpVariable initializer) and for every zero-value composite, so this is the
    // single largest undeclared-id source on naga-produced SPIR-V. Fold each null
    // to the zero literal of its own type, exactly like the OpUndef fold above.
    // Pointer/image/sampler-typed nulls have no WGSL value literal and keep their
    // counter name (naga never emits them; a use site stays visibly broken rather
    // than silently inventing a value). (#wgsl-cts)
    for (module.instructions) |inst| {
        if (inst.op != .ConstantNull or inst.words.len <= 2) continue;
        const z = zeroLiteralOfType(module, inst.words[1], names, alloc) orelse continue;
        if (names.fetchPut(inst.words[2], z) catch null) |old| alloc.free(old.value);
    }

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
    // naga rejects as an unknown identifier. zioshade's own frontend only
    // attaches OpName to globals/functions/spec-constants, but external
    // SPIR-V (glslang, hand-crafted) freely names plain constants, so the
    // skip is required for `spirvToWGSL` as a public API.
    for (module.instructions) |inst| {
        if (inst.op != .Name or inst.words.len < 3) continue;
        const id = inst.words[1];
        const target = getDef(module, id) orelse continue;
        switch (target.op) {
            .Constant,
            .ConstantTrue,
            .ConstantFalse,
            .ConstantComposite,
            .SpecConstant,
            .SpecConstantTrue,
            .SpecConstantFalse,
            .SpecConstantComposite,
            .SpecConstantOp,
            .Undef, // collectNames folds OpUndef to a zero literal (e.g. "false"); the
            // keyword-rename below must not append '_' to that literal.
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

/// True if member `member_index` of `struct_id` is decorated NoPerspective. (#475)
fn memberHasNoPerspective(module: *const ParsedModule, struct_id: u32, member_index: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op == .MemberDecorate and inst.words.len >= 4 and
            inst.words[1] == struct_id and inst.words[2] == member_index)
        {
            const dec: spirv.Decoration = @enumFromInt(inst.words[3]);
            if (dec == .no_perspective) return true;
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

/// Where a buffer's raw bytes live in a composite VALUE: `raw` means the value
/// came straight from a load of memory typed with the RowMajor member
/// decoration (so a row-major member inside it reads as the TRANSPOSE of the
/// logical matrix in WGSL's column-major-only world), `logical` means the value
/// was assembled in registers (the logical matrix itself). The RowMajor
/// decoration describes the BUFFER layout only -- a CompositeConstruct of the
/// same struct type holds logical bytes and must NOT be transposed -- so
/// provenance, not the type alone, decides compensation. `unknown` (function
/// call results, selects, mixed phis) cannot be proven and must not be guessed.
const ValueBytes = enum { raw, logical, unknown };

fn valueBytesProvenance(module: *const ParsedModule, id: u32, depth: u8) ValueBytes {
    if (depth > 8) return .unknown;
    const def = getDef(module, id) orelse return .unknown;
    switch (def.op) {
        // A load reads memory through the decorated type: raw bytes.
        .Load => return .raw,
        .CopyObject => {
            if (def.words.len < 4) return .unknown;
            return valueBytesProvenance(module, def.words[3], depth + 1);
        },
        // Assembled in registers: logical bytes.
        .CompositeConstruct, .ConstantComposite, .ConstantNull => return .logical,
        // A sub-value extract keeps its source's bytes UNLESS it crosses a
        // row-major matrix -- a crossing extract is transposed at emission, so
        // its RESULT value is the logical matrix (compensated), while a
        // non-crossing sub-struct/sub-array still holds raw bytes.
        .CompositeExtract => {
            if (def.words.len < 5) return .unknown;
            const src = valueBytesProvenance(module, def.words[3], depth + 1);
            if (src == .unknown) return .unknown;
            if (src == .raw and findRowMajorExtract(module, def.words[3], def.words[4..]) != null) return .logical;
            return src;
        },
        // A phi joins values; all incomings must agree (words alternate
        // value, parent-block, so step by 2).
        .Phi => {
            if (def.words.len < 4) return .unknown;
            var saw_raw = false;
            var saw_logical = false;
            var i: usize = 3;
            while (i < def.words.len) : (i += 2) {
                switch (valueBytesProvenance(module, def.words[i], depth + 1)) {
                    .raw => saw_raw = true,
                    .logical => saw_logical = true,
                    .unknown => return .unknown,
                }
            }
            if (saw_raw and !saw_logical) return .raw;
            if (saw_logical and !saw_raw) return .logical;
            return .unknown;
        },
        else => return .unknown,
    }
}

/// If the LITERAL `indices` of an OpCompositeExtract walk from the composite
/// VALUE `value_id` into a row-major SQUARE matrix member (a direct member or
/// a matrix-array element inside the loaded type), return the boundary: the
/// extract indices up to and including `boundary` produce the RAW (transposed)
/// matrix value, and the remaining indices index into the LOGICAL matrix.
/// Mirrors `findRowMajorMatrix` (which walks pointer chains with index IDs)
/// for value-side literal indices; the caller must gate on
/// `valueBytesProvenance` before transposing.
fn findRowMajorExtract(module: *const ParsedModule, value_id: u32, indices: []const u32) ?RowMajorAccess {
    var cur_type: ?u32 = resolveTypeOf(module, value_id);
    var member_row_major = false; // did the enclosing struct member carry RowMajor?
    for (indices, 0..) |val, i| {
        const tid = cur_type orelse return null;
        const ti = getDef(module, tid) orelse return null;
        if (ti.op == .TypeStruct) {
            if (val + 2 >= ti.words.len) return null;
            member_row_major = memberIsRowMajor(module, tid, val);
            const member_tid = ti.words[val + 2];
            const mdef = getDef(module, member_tid);
            if (mdef != null and mdef.?.op == .TypeMatrix and member_row_major) {
                if (matrixIsSquare(module, member_tid)) return .{ .boundary = i, .matrix_tid = member_tid };
                return null; // non-square: honest error at declaration
            }
            cur_type = member_tid;
        } else if (ti.op == .TypeArray) {
            const elem = ti.words[2];
            const edef = getDef(module, elem);
            if (edef != null and edef.?.op == .TypeMatrix and member_row_major) {
                if (matrixIsSquare(module, elem)) return .{ .boundary = i, .matrix_tid = elem };
                return null; // non-square: honest error at declaration
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
                try buf.appendSlice(alloc, switch (val) {
                    0 => ".x",
                    1 => ".y",
                    2 => ".z",
                    3 => ".w",
                    else => ".x",
                });
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
/// Append the PREFIX of a transposed row-major extract: the literal indices
/// that produce the raw matrix value, spelled exactly like the plain
/// CompositeExtract path (struct member `.name`, array/matrix element `[n]`).
/// True if `type_id` (a struct) contains a row_major SQUARE matrix member at
/// any struct-nesting depth. Locals of such a type are read through the
/// type-driven transpose of `findRowMajorMatrix`, so every store into them must
/// keep RAW bytes (see the Store arm's whole-struct compensation).
fn structContainsRowMajorMatrix(module: *const ParsedModule, type_id: u32) bool {
    const ti = getDef(module, type_id) orelse return false;
    if (ti.op != .TypeStruct or ti.words.len < 3) return false;
    for (ti.words[2..], 0..) |member_tid, i| {
        if (memberIsRowMajor(module, type_id, @intCast(i))) {
            // Direct matrix or (array of) matrix: reads transpose per element,
            // so the member counts regardless of array nesting.
            var elem = member_tid;
            while (true) {
                const ed = getDef(module, elem) orelse break;
                if (ed.op == .TypeMatrix) {
                    if (matrixIsSquare(module, elem)) return true;
                    break;
                }
                if (ed.op != .TypeArray and ed.op != .TypeRuntimeArray) break;
                elem = ed.words[2];
            }
        }
        const mdef = getDef(module, member_tid) orelse continue;
        if (mdef.op == .TypeStruct) {
            if (structContainsRowMajorMatrix(module, member_tid)) return true;
        }
    }
    return false;
}

/// Emit the compensating assignments after a WHOLE-STRUCT store of a LOGICAL
/// (register-assembled) value into a local whose reads transpose row_major
/// members: copy the struct plainly first, then overwrite every row_major
/// matrix member with its transpose so the local holds RAW bytes again.
/// Returns an error if a member needs per-element work we do not emit
/// (row_major matrix arrays) -- honest refusal over a wrong partial copy.
fn writeRowMajorStructCompensation(module: *const ParsedModule, struct_tid: u32, target_name: []const u8, value_name: []const u8, path: []const u8, w: anytype, indent: u32) !void {
    const ti = getDef(module, struct_tid) orelse return;
    if (ti.op != .TypeStruct or ti.words.len < 3) return;
    for (ti.words[2..], 0..) |member_tid, i| {
        var mname_buf: [32]u8 = undefined;
        const mname = getMemberName(module, struct_tid, @intCast(i), &mname_buf);
        if (memberIsRowMajor(module, struct_tid, @intCast(i))) {
            const mt = getDef(module, member_tid);
            if (mt != null and mt.?.op == .TypeMatrix and matrixIsSquare(module, member_tid)) {
                try writeIndentStatic(w, indent);
                try w.print("{s}.{s}{s} = transpose({s}.{s}{s});\n", .{ target_name, path, mname, value_name, path, mname });
                continue;
            }
            // A row_major matrix ARRAY needs per-element transposes the plain
            // struct copy cannot provide.
            return error.UnsupportedRowMajorMatrixStore;
        }
        const md = getDef(module, member_tid) orelse continue;
        if (md.op == .TypeStruct and structContainsRowMajorMatrix(module, member_tid)) {
            var nested_buf: [80]u8 = undefined;
            const nested = std.fmt.bufPrint(&nested_buf, "{s}{s}.", .{ path, mname }) catch return error.UnsupportedRowMajorMatrixStore;
            try writeRowMajorStructCompensation(module, member_tid, target_name, value_name, nested, w, indent);
        }
    }
}

fn appendExtractPrefix(module: *const ParsedModule, value_id: u32, indices: []const u32, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var cur_type: ?u32 = resolveTypeOf(module, value_id);
    for (indices) |val| {
        const ti = if (cur_type) |t| getDef(module, t) else null;
        if (ti) |t| {
            if (t.op == .TypeStruct) {
                var mname_buf: [32]u8 = undefined;
                const mname = getMemberName(module, cur_type.?, val, &mname_buf);
                try buf.print(alloc, ".{s}", .{mname});
                cur_type = if (val + 2 < t.words.len) t.words[val + 2] else null;
            } else if (t.op == .TypeVector) {
                try buf.appendSlice(alloc, switch (val) {
                    0 => ".x",
                    1 => ".y",
                    2 => ".z",
                    3 => ".w",
                    else => ".x",
                });
                cur_type = t.words[2];
            } else {
                try buf.print(alloc, "[{d}]", .{val});
                cur_type = t.words[2];
            }
        } else {
            try buf.print(alloc, "[{d}]", .{val});
            cur_type = null;
        }
    }
}

/// Append the indices that come AFTER a (transposed) row-major matrix in a
/// CompositeExtract: they index the LOGICAL matrix, so a column index is `[n]`
/// (WGSL `m[n]` is a column read) and a vector element is a `.xyzw` swizzle.
/// Literal-index sibling of `appendMatrixTail`.
fn appendMatrixTailLiterals(module: *const ParsedModule, matrix_tid: u32, indices: []const u32, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var cur_type: ?u32 = matrix_tid;
    for (indices) |val| {
        const ti = if (cur_type) |t| getDef(module, t) else null;
        if (ti) |t| {
            if (t.op == .TypeVector) {
                try buf.appendSlice(alloc, switch (val) {
                    0 => ".x",
                    1 => ".y",
                    2 => ".z",
                    3 => ".w",
                    else => ".x",
                });
                cur_type = t.words[2];
            } else {
                try buf.print(alloc, "[{d}]", .{val});
                cur_type = if (t.op == .TypeMatrix or t.op == .TypeArray) t.words[2] else null;
            }
        } else {
            try buf.print(alloc, "[{d}]", .{val});
            cur_type = null;
        }
    }
}

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
                        0 => ".x",
                        1 => ".y",
                        2 => ".z",
                        3 => ".w",
                        else => ".x",
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
        // OpConstantNull/True/False are naga's initializers for every plain
        // `var<private> x: T;` / `var<private> b: bool = true;` global. The
        // Private-var emitter SKIPS a declaration whose initializer does not
        // resolve (rather than zero-initialise silently-wrong values), so an
        // unfoldable one left every use site referencing an undeclared
        // identifier at exit 0. Null folds to the zero literal of its own type
        // (exactly what a WGSL var<private> without initializer holds, so the
        // fold is value-faithful, not a fallback). (#wgsl-cts)
        .ConstantNull => {
            if (inst.words.len < 3) return null;
            return zeroLiteralOfType(module, inst.words[1], names, arena);
        },
        .ConstantTrue => return "true",
        .ConstantFalse => return "false",
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

/// Resolve a texture/sampler VALUE id (the operands of a call-site
/// OpSampledImage) back to the module-level OpVariable it was loaded from.
/// Returns null unless the chain is OpLoad(Variable) or a bare Variable AND the
/// variable lives in UniformConstant (the resource-declaration class); a
/// function-parameter sampler or anything else has no module declaration to
/// type, so the caller keeps refusing it.
fn resolveUniformConstantVar(module: *const ParsedModule, value_id: u32) ?u32 {
    var vid = value_id;
    if (getDef(module, vid)) |d| {
        if (d.op == .Load and d.words.len > 3) vid = d.words[3];
    }
    const v = getDef(module, vid) orelse return null;
    if (v.op != .Variable or v.words.len < 4) return null;
    const sc: spirv.StorageClass = @enumFromInt(v.words[3]);
    if (sc != .UniformConstant) return null;
    return vid;
}

/// Classify each module-level sampler VARIABLE by the image ops its call-site
/// OpSampledImage results feed: `dref_vars` collected a depth-COMPARE op
/// (OpImageSampleDref*/OpImageProjDref*/OpImageDrefGather), `plain_vars` a
/// non-compare image op. SPIR-V samplers are opaque (comparison-ness lives in
/// WHICH op samples with them, not the type), while WGSL types the BINDING:
/// `sampler_comparison` vs `sampler`. A sampler feeding only dref ops must be
/// declared sampler_comparison; one feeding only plain ops stays `sampler`;
/// one feeding BOTH cannot be typed by a single WGSL binding (the caller
/// refuses that). An OpSampledImage with no consuming image op is dead and
/// contributes nothing.
const SamplerUses = struct {
    dref_vars: std.AutoHashMap(u32, void),
    plain_vars: std.AutoHashMap(u32, void),
};

fn isDrefSampleOp(op: spirv.Op) bool {
    return switch (op) {
        .ImageSampleDrefImplicitLod,
        .ImageSampleDrefExplicitLod,
        .ImageSampleProjDrefImplicitLod,
        .ImageSampleProjDrefExplicitLod,
        .ImageDrefGather,
        => true,
        else => false,
    };
}

fn collectSamplerUses(module: *const ParsedModule, alloc: std.mem.Allocator) SamplerUses {
    var uses = SamplerUses{
        .dref_vars = std.AutoHashMap(u32, void).init(alloc),
        .plain_vars = std.AutoHashMap(u32, void).init(alloc),
    };
    // Pass 1: classify each OpSampledImage result id by its consumers.
    // Bit 1 = plain image op, bit 2 = dref op, 3 = sampled both ways.
    var si_class = std.AutoHashMap(u32, u2).init(alloc);
    defer si_class.deinit();
    {
        var sampled_image_results = std.AutoHashMap(u32, void).init(alloc);
        defer sampled_image_results.deinit();
        for (module.instructions) |si| {
            if (si.op == .SampledImage and si.words.len > 2) {
                sampled_image_results.put(si.words[2], {}) catch {};
            }
        }
        for (module.instructions) |inst| {
            const consumes_sampled_image = switch (inst.op) {
                .ImageSampleImplicitLod,
                .ImageSampleExplicitLod,
                .ImageSampleDrefImplicitLod,
                .ImageSampleDrefExplicitLod,
                .ImageSampleProjImplicitLod,
                .ImageSampleProjExplicitLod,
                .ImageSampleProjDrefImplicitLod,
                .ImageSampleProjDrefExplicitLod,
                .ImageGather,
                .ImageDrefGather,
                => inst.words.len > 3 and sampled_image_results.contains(inst.words[3]),
                else => false,
            };
            if (!consumes_sampled_image) continue;
            const cls: u2 = if (isDrefSampleOp(inst.op)) 2 else 1;
            const gop = si_class.getOrPut(inst.words[3]) catch continue;
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) | cls;
        }
    }
    // Pass 2: attribute each classified OpSampledImage to its sampler variable.
    var it = si_class.iterator();
    while (it.next()) |e| {
        const si = getDef(module, e.key_ptr.*) orelse continue;
        if (si.op != .SampledImage or si.words.len < 5) continue;
        const sv = resolveUniformConstantVar(module, si.words[4]) orelse continue;
        if (e.value_ptr.* & 2 != 0) uses.dref_vars.put(sv, {}) catch {};
        if (e.value_ptr.* & 1 != 0) uses.plain_vars.put(sv, {}) catch {};
    }
    return uses;
}

fn resolvePointee(module: *const ParsedModule, id: u32) ?u32 {
    // First try direct TypePointer
    if (common.resolvePointeeType(module, id)) |pt| return pt;
    // Resolve through value-producing instructions whose words[1] is a result
    // TYPE that may be a TypePointer: a Variable, a pointer FunctionParameter
    // (the real ptr<function> inout path), a CopyObject of a pointer, or a
    // chained AccessChain result. Without FunctionParameter here, a pointer
    // param's pointee type is unknown to buildAccessExprPlain, so it cannot
    // detect the pointee is a struct and lowers a constant struct-member index
    // to array-index `[i]` syntax -- WGSL forbids indexing a struct ("cannot
    // index type 'BST'") -- instead of `.memberName` member access.
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .Variable, .FunctionParameter, .CopyObject, .AccessChain => {
            if (inst.words.len > 1) return common.resolvePointeeType(module, inst.words[1]);
            return null;
        },
        else => return null,
    }
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
            .AtomicIAdd,
            .AtomicISub,
            .AtomicAnd,
            .AtomicOr,
            .AtomicXor,
            .AtomicUMin,
            .AtomicSMin,
            .AtomicUMax,
            .AtomicSMax,
            .AtomicFAddEXT,
            .AtomicExchange,
            .AtomicCompareExchange,
            .AtomicStore,
            => true,
            else => false,
        };
        if (!is_atomic) continue;
        if (inst.words.len < 4) continue;
        // OpAtomicStore has no result type/id: its pointer is words[1]; every
        // result-producing atomic op carries it at words[3].
        const ptr_id = if (inst.op == .AtomicStore) inst.words[1] else inst.words[3];
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
            .AtomicIAdd,
            .AtomicISub,
            .AtomicAnd,
            .AtomicOr,
            .AtomicXor,
            .AtomicUMin,
            .AtomicSMin,
            .AtomicUMax,
            .AtomicSMax,
            .AtomicFAddEXT,
            .AtomicExchange,
            .AtomicCompareExchange,
            .AtomicStore,
            => true,
            else => false,
        };
        if (!is_atomic) continue;
        if (inst.words.len < 4) continue;
        // OpAtomicStore's pointer is words[1] (no result type/id; see
        // collectAtomicFields).
        const atomic_ptr_id = if (inst.op == .AtomicStore) inst.words[1] else inst.words[3];
        const ptr_inst = common.getDef(module, atomic_ptr_id) orelse continue;
        if (ptr_inst.op != .Variable or ptr_inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(ptr_inst.words[3]);
        // Workgroup only: the decl-wrapping below rewrites `var<workgroup>` to
        // `atomic<T>`. A Private-storage atomic target would get its load/store
        // rewritten to atomicLoad/atomicStore WITHOUT an atomic<> decl (mismatch),
        // but GLSL has no construct that produces a Private-storage atomic target,
        // so restricting here keeps the load/store rewrites consistent with the
        // decl. (Review follow-up.)
        if (sc == .Workgroup) {
            try out.put(atomic_ptr_id, {});
        }
    }
}

/// Resolve whether `ptr_id` (an OpLoad/OpStore pointer operand) denotes a plain
/// access to an SSBO struct field that `collectAtomicFields` declared `atomic<T>`.
/// Such a field's plain OpLoad/OpStore must lower to atomicLoad/atomicStore --
/// naga rejects `let v = b.x;` on an atomic field: "atomic variables cannot be
/// accessed directly". Mirrors the index walk in `collectAtomicFields`: the
/// deepest struct-member access along the AccessChain is the candidate, and if
/// `(struct_id, member_idx)` is present in `atomic_fields` the access is atomic.
/// Returns null for a non-AccessChain pointer or a non-atomic field.
fn resolveAtomicFieldAccess(module: *const ParsedModule, ptr_id: u32, atomic_fields: *const AtomicFieldMap) ?AtomicFieldKind {
    const ptr_inst = common.getDef(module, ptr_id) orelse return null;
    if (ptr_inst.op != .AccessChain) return null;
    if (ptr_inst.words.len < 5) return null; // need base + at least one index
    const base_id = ptr_inst.words[3];

    var current_type_id: ?u32 = resolvePointee(module, base_id);
    var last_struct_id: ?u32 = null;
    var last_member_idx: u32 = 0;

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
                if (mi + 2 < ti.words.len) current_type_id = ti.words[mi + 2] else current_type_id = null;
            },
            .TypeArray, .TypeRuntimeArray, .TypeVector, .TypeMatrix => {
                if (ti.words.len > 2) current_type_id = ti.words[2] else current_type_id = null;
            },
            else => break,
        }
    }

    if (last_struct_id) |sid| {
        return atomic_fields.get(.{ .struct_id = sid, .member_idx = last_member_idx });
    }
    return null;
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

/// True if a UNIFORM (non-SSBO) block struct has a single-level array member
/// whose ArrayStride is a KNOWN value that is not a multiple of 16. WGSL's
/// uniform address space requires every array element stride to be a multiple of
/// 16. std430 / scalar-block-layout uniform and push-constant blocks pack arrays
/// TIGHTLY (`float Arr[4]` → stride 4; `vec2 v[2]` → stride 8), and zioshade cannot
/// widen them to vec4 without reading WRONG DATA from the host (it packs elements
/// at 0,4,8,12 — not 0,16,32,48; this is exactly why collectWrappedUniformMembers-
/// ForStruct only wraps stride-16 members). Such a block has no faithful core-WGSL
/// uniform form, so emitting it as `var<uniform>` is naga-rejected at exit 0 =
/// silent-wrong (#170). Detect it so the caller can honest-error instead.
/// Stride-16 (std140) array members are widened and validate — `% 16 == 0` skips
/// them; SSBOs (storage space tolerates the tight layout) are excluded by the
/// caller's `!cb.is_ssbo` filter. (tests/spirv-cross/push-constant.flatten.vert.)
fn uniformBlockHasUnrepresentableSub16Array(module: *const ParsedModule, struct_type_id: u32) bool {
    const sdef = getDef(module, struct_type_id) orelse return false;
    if (sdef.op != .TypeStruct or sdef.words.len <= 2) return false;
    for (sdef.words[2..]) |mt_id| {
        const md = getDef(module, mt_id) orelse continue;
        if (md.op != .TypeArray and md.op != .TypeRuntimeArray) continue;
        const stride = arrayTypeStride(module, mt_id) orelse continue;
        if (stride % 16 != 0) return true;
    }
    return false;
}

/// Resolve the value type of an ID by tracing its defining instruction.
fn resolveTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .Variable => {
            if (inst.words.len > 1) return common.resolvePointeeType(module, inst.words[1]);
            return null;
        },
        .Load,
        .CopyObject,
        .CompositeConstruct,
        .CompositeInsert,
        .FunctionCall,
        .Phi,
        .Select,
        .CopyLogical,
        .FunctionParameter,
        .Undef,
        // Composite constants carry their result type in words[1] too — needed so
        // an OpCompositeExtract from an inline `array<...>(...)` constant is typed
        // as an array (indexed `[i]`), not swizzled `.x`.
        .ConstantComposite,
        .SpecConstantComposite,
        .Constant,
        .ConstantTrue,
        .ConstantFalse,
        .SpecConstant,
        .ConvertFToS,
        .ConvertSToF,
        .ConvertUToF,
        .ConvertFToU,
        .UConvert,
        .SConvert,
        .FConvert,
        .Bitcast,
        .QuantizeToF16,
        .VectorShuffle,
        .CompositeExtract,
        .VectorTimesScalar,
        .MatrixTimesScalar,
        .VectorTimesMatrix,
        .MatrixTimesVector,
        .MatrixTimesMatrix,
        .OuterProduct,
        .Transpose,
        .ImageSampleImplicitLod,
        .ImageSampleExplicitLod,
        .ImageFetch,
        .ImageRead,
        .FNegate,
        .SNegate,
        .Not,
        .LogicalNot,
        .ExtInst,
        .FAdd,
        .FSub,
        .FMul,
        .FDiv,
        .FRem,
        .FMod,
        .IAdd,
        .ISub,
        .IMul,
        .SDiv,
        .UDiv,
        .SMod,
        .UMod,
        .ShiftRightLogical,
        .ShiftRightArithmetic,
        .ShiftLeftLogical,
        .BitwiseAnd,
        .BitwiseOr,
        .BitwiseXor,
        .FOrdLessThan,
        .FOrdGreaterThan,
        .FOrdLessThanEqual,
        .FOrdGreaterThanEqual,
        .FOrdEqual,
        .FOrdNotEqual,
        .FUnordNotEqual,
        .LogicalAnd,
        .LogicalOr,
        .LogicalEqual,
        .LogicalNotEqual,
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

/// Detect module-scope Private variables that are functionally LOCALS and map
/// them to the value their one store writes: exactly ONE direct OpStore, that
/// store and its value both defined in the owning function's ENTRY block (or
/// the value is a FunctionParameter of it), every access (the store plus all
/// direct OpLoads) inside that ONE function and after the store, and NO other
/// reference of any kind (no AccessChain, atomic, or copy access). For a var
/// in this map the emitters alias every OpLoad to the stored value's name,
/// suppress the store, and skip the module-scope `var<private>` declaration.
///
/// WHY (the subgroup uniformity fix): WGSL requires uniform-value arguments
/// (the subgroup shuffle deltas, broadcast/quad ids) to be provably uniform,
/// and tint's uniformity analysis conservatively treats ANY module-scope
/// `var<private>` written at runtime as non-uniform ("reading from
/// module-scope private variable may result in a non-uniform value"). tint's
/// own SPIR-V writer lowers `subgroupShuffleXor(e, delta)` to
/// `delta & (subgroup_size - 1)` THROUGH exactly such a var
/// (`tint_subgroup_size_mask`, stored once at function entry), so without this
/// forwarding every round-tripped shuffle lowers to a call tint itself
/// rejects. Forwarding to the entry-block value restores the analysis's view
/// of the value's uniformity (it derives from a function parameter, itself
/// passed the subgroup_size builtin).
///
/// Semantically the forwarding is exact: a single store that dominates every
/// load (entry block, all accesses in one function, store first in linear
/// order) means each load reads the stored value; a function-local var would
/// be identical minus the declaration. Anything that could break that
/// domination (a second store, a store under control flow, accesses from a
/// second function, any non-load/store reference) disqualifies the var, which
/// then keeps its ordinary `var<private>` lowering.
fn buildSingleStorePrivateForwarding(module: *const ParsedModule, arena: std.mem.Allocator) void {
    forward_private_stores = .empty;
    // id -> instruction index, for the entry-block checks.
    var def_idx = std.AutoHashMap(u32, usize).init(arena);
    defer def_idx.deinit();
    for (module.instructions, 0..) |inst, ii| {
        if (inst.words.len >= 3) def_idx.put(inst.words[2], ii) catch return;
    }
    for (module.instructions) |vinst| {
        if (vinst.op != .Variable or vinst.words.len < 4) continue;
        if (@as(spirv.StorageClass, @enumFromInt(vinst.words[3])) != .Private) continue;
        const vid = vinst.words[2];
        var store: ?usize = null; // instruction index of the single OpStore
        var store_value: u32 = 0;
        var store_func: ?usize = null; // instruction index of the owning OpFunction
        var load_func: ?usize = null;
        var n_loads: usize = 0;
        var qualified = true;
        var cur_func: ?usize = null;
        for (module.instructions, 0..) |inst, ii| {
            switch (inst.op) {
                .Function => {
                    cur_func = ii;
                    continue;
                },
                .FunctionEnd => {
                    cur_func = null;
                    continue;
                },
                // Metadata referencing the id is not an access, nor is the
                // variable's own declaration (its initializer, if any, DOES
                // count and is caught by the word sweep below).
                .Name, .MemberName, .Decorate, .MemberDecorate => continue,
                .Variable => if (inst.words.len >= 3 and inst.words[2] == vid) continue,
                else => {},
            }
            if (inst.op == .Store and inst.words.len >= 3 and inst.words[1] == vid) {
                if (store != null) {
                    qualified = false; // more than one store
                    break;
                }
                store = ii;
                store_value = inst.words[2];
                store_func = cur_func;
                continue;
            }
            if (inst.op == .Load and inst.words.len > 3 and inst.words[3] == vid) {
                n_loads += 1;
                if (store == null or ii < store.?) {
                    qualified = false; // load before the (single) store
                    break;
                }
                if (load_func == null) load_func = cur_func;
                if (load_func != cur_func or cur_func == null) {
                    qualified = false; // loads span functions / no function
                    break;
                }
                continue;
            }
            // Any other POINTER-OPERAND mention of vid disqualifies the var
            // (it must keep a real declaration): an AccessChain rooted at it,
            // an atomic, a copy, an array-length, an image-texel pointer. The
            // check is keyed on the ops that can take a variable pointer --
            // NOT a raw word scan, whose literal operands (constant values,
            // type widths, execution modes) numerically collide with ids.
            const ptr_word: ?u32 = switch (inst.op) {
                .AccessChain, .ArrayLength, .ImageTexelPointer => if (inst.words.len > 3) inst.words[3] else null,
                .AtomicLoad, .AtomicExchange, .AtomicIAdd, .AtomicISub, .AtomicSMin, .AtomicUMin, .AtomicSMax, .AtomicUMax, .AtomicAnd, .AtomicOr, .AtomicXor, .AtomicFAddEXT, .AtomicCompareExchange, .AtomicCompareExchangeWeak, .AtomicIIncrement, .AtomicIDecrement => if (inst.words.len > 3) inst.words[3] else null,
                .AtomicStore => if (inst.words.len > 1) inst.words[1] else null,
                .CopyMemory => blk: {
                    if (inst.words.len > 3) {
                        if (inst.words[1] == vid or inst.words[2] == vid) break :blk vid;
                    }
                    break :blk null;
                },
                else => null,
            };
            if (ptr_word != null and ptr_word.? == vid) {
                qualified = false;
                break;
            }
        }
        if (!qualified or store == null or n_loads == 0) continue;
        if (store_func == null or load_func == null or store_func.? != load_func.?) continue;
        // The store must sit in the owning function's ENTRY block: from the
        // first Label after the OpFunction to the first block terminator.
        const fn_start = store_func.?;
        var entry_start: ?usize = null;
        var entry_end: usize = module.instructions.len;
        var j = fn_start + 1;
        while (j < module.instructions.len) : (j += 1) {
            const t = module.instructions[j];
            if (entry_start == null) {
                if (t.op == .Label) {
                    entry_start = j;
                } else if (t.op != .FunctionParameter) {
                    break; // malformed function; do not forward
                }
                continue;
            }
            switch (t.op) {
                .Branch, .BranchConditional, .Switch, .Kill, .Return, .ReturnValue, .Unreachable => {
                    entry_end = j;
                    break;
                },
                else => {},
            }
        }
        if (entry_start == null or store.? < entry_start.? or store.? >= entry_end) continue;
        // The stored VALUE must be a function parameter (its instructions sit
        // between the OpFunction and the first Label, and its name is in scope
        // for the whole function) or be defined in that same entry block --
        // only then is its name in scope at every load, including loads inside
        // later conditional/loop blocks.
        const vd = getDef(module, store_value) orelse continue;
        if (vd.op != .FunctionParameter) {
            const vi = def_idx.get(store_value) orelse continue;
            if (vi < entry_start.? or vi >= entry_end) continue;
        }
        forward_private_stores.put(arena, vid, store_value) catch {};
    }
}

pub fn spirvToWGSL(alloc: std.mem.Allocator, spirv_words_in: []const u32, options: WgslCompileOptions) ![]const u8 {
    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V (no-op on
    // structured input; fall back to the original on failure — see spirvToGLSL).
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words_in) catch null;
    defer if (_norm) |n| alloc.free(n);
    const spirv_words = _norm orelse spirv_words_in;
    last_error_detail = null; // clear any detail from a prior compile on this thread
    forward_private_stores = .empty; // same for the private-store forwarding map
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
                .{std.enums.tagName(spirv.ExecutionModel, module.execution_model) orelse "unknown"},
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
    // (texture_depth_2d + sampler_comparison) and comparison-ness to the SAMPLER
    // binding, so this shape lowers cleanly ONLY when the whole module agrees:
    //   1. the sampler variable feeds ONLY dref ops (a binding typed
    //      sampler_comparison cannot also serve a plain textureSample), and
    //   2. the dref op's texture is a DEPTH image (Depth=1), so texture_depth_*
    //      matches the SPIR-V image type verbatim, and
    //   3. the sampler resolves to a module-level UniformConstant variable
    //      (a function-parameter sampler has no declaration to type).
    // Anything else keeps failing loud rather than emit a mistyped binding.
    // A COMBINED sampler2DShadow global (no call-site OpSampledImage) is
    // unaffected: it is handled by the texture's sampler_comparison partner.
    {
        var guard_aa = std.heap.ArenaAllocator.init(alloc);
        defer guard_aa.deinit();
        const sampler_uses = collectSamplerUses(&module, guard_aa.allocator());
        // (1) mixed-use sampler: refuse before emission; the declaration site
        // below types a dref-only sampler as sampler_comparison, so a sampler
        // that also feeds a plain sample would silently change that call's
        // meaning (naga: "Comparison sampling mismatch").
        var mixed_it = sampler_uses.dref_vars.iterator();
        while (mixed_it.next()) |e| {
            if (sampler_uses.plain_vars.contains(e.key_ptr.*)) {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL types one sampler binding either sampler or sampler_comparison, never both; this sampler feeds both a depth-compare op (textureSampleCompare/textureGatherCompare) and a non-compare sample",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            }
        }
        // (2)+(3) every call-site dref op needs a depth texture and a
        // module-level sampler variable.
        for (module.instructions) |inst| {
            if (!isDrefSampleOp(inst.op) or inst.words.len < 4) continue;
            const si = getDef(&module, inst.words[3]) orelse continue;
            if (si.op != .SampledImage or si.words.len < 5) continue;
            // OpSampledImage layout: [1]=result type [2]=result [3]=image [4]=sampler.
            if (resolveUniformConstantVar(&module, si.words[4]) == null) {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL comparison sampling through a sampler that is not a module-level variable has no binding to type sampler_comparison",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            }
            const tex_var = resolveUniformConstantVar(&module, si.words[3]) orelse {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL comparison sampling through a texture that is not a module-level variable has no binding to type texture_depth_*",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            };
            const tex_ptr_type = common.resolvePointeeType(&module, getTypeOf(&module, tex_var) orelse continue) orelse continue;
            if (!imageTypeIsDepth(&module, tex_ptr_type)) {
                last_error_detail = std.fmt.bufPrint(
                    &last_error_detail_buf,
                    "WGSL textureSampleCompare/textureGatherCompare require a texture_depth_* texture; the SPIR-V image sampled with a Dref is not a depth image (Depth=0), and retyping the binding would change what it may bind",
                    .{},
                ) catch null;
                return error.UnsupportedOp;
            }
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
    // WGSL core has no array-of-opaque support (binding_array is non-core), so BOTH
    // the bounded (`tex[N]`) and unbounded (`tex[]`, GL_EXT_nonuniform_qualifier)
    // forms must fail loud — the unbounded form otherwise dropped the variable
    // declaration and emitted an undeclared `tex[i]` + malformed `tex[i]_sampler`. (#170)
    if (common.hasOpaqueArrayResource(&module, true)) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL backend does not yet support descriptor sampler/image arrays", .{}) catch null;
        return error.UnsupportedSamplerArray;
    }

    // WGSL has no 64-bit numeric types in core — neither f64 (GLSL `double`) nor
    // i64/u64 (`int64_t`/`uint64_t`). `wgslType` collapses every OpTypeFloat to `f32`
    // and every OpTypeInt to i32/u32 REGARDLESS of width, so a 64-bit shader silently
    // truncates: an f64 constant is misread (the 64-bit IEEE-754 bit pattern
    // reinterpreted as f32 = garbage), and a 64-bit int constant is truncated to 32
    // bits (e.g. 1e12 → garbage). Both validate under naga while computing WRONG
    // values, so fail loud on any 64-bit numeric type. (umulExtended/imulExtended do
    // NOT introduce an OpTypeInt-64 type — their result is two 32-bit halves — so this
    // is independent of that ExtInst honest-error path.) (#170)
    for (module.instructions) |finst| {
        if (finst.words.len > 2 and finst.words[2] == 64) {
            if (finst.op == .TypeFloat) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no 64-bit float (double) type", .{}) catch null;
                return error.UnsupportedDoubleType;
            }
            if (finst.op == .TypeInt) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no 64-bit integer (int64_t/uint64_t) type", .{}) catch null;
                return error.UnsupportedInt64Type;
            }
        }
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

    // Apply single-store private forwarding at the NAME level as well: rename
    // every forwarded load's RESULT to the stored value's name right after
    // collectNames, so pre-emission scans (inline-expression building, loop
    // hoisting) and the resolvers all see the forwarded value, never the
    // suppressed variable. The Load arm still skips the declaration (without
    // it the general path would emit `let <value>: T = <var>;`).
    {
        var fit = forward_private_stores.iterator();
        while (fit.next()) |entry| {
            const value_name = names.get(entry.value_ptr.*) orelse continue;
            for (module.instructions) |inst| {
                if (inst.op != .Load or inst.words.len <= 3 or inst.words[3] != entry.key_ptr.*) continue;
                const a = alloc.dupe(u8, value_name) catch continue;
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            }
        }
    }

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
    const w = compat.listWriter(&out, alloc);

    try w.writeAll("// Generated by zioshade SPIR-V -> WGSL cross-compiler\n\n");

    // Single-entry-block-store private-var forwarding (see the builder's doc
    // comment): must run before the Private module-scope emitter and before
    // any function body, since both consult the map it fills.
    buildSingleStorePrivateForwarding(&module, arena);

    // `enable subgroups;` -- required by every subgroup builtin the backend
    // lowers (subgroupAdd/subgroupBallot/quadSwap/... and the
    // subgroup_invocation_id/subgroup_size @builtins). WGSL demands the enable
    // precede every declaration, so it is written right after the header and
    // before the matrix-inverse helpers. The pre-scan covers ops in ANY
    // function (helpers included), not just the entry body. Emitting it when a
    // pruned dead function held the op is harmless (an unused enable is valid
    // WGSL); NOT emitting it for a live one would be invalid output.
    {
        var subgroups_used = false;
        for (module.instructions) |inst| {
            if (opIsLoweredSubgroup(inst.op)) {
                subgroups_used = true;
                break;
            }
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc != .Input) continue;
                if (getDecVal(&decorations, inst.words[2], .built_in)) |bv| {
                    if (builtInNeedsSubgroupsEnable(@enumFromInt(bv))) {
                        subgroups_used = true;
                        break;
                    }
                }
            }
        }
        if (subgroups_used) try w.writeAll("enable subgroups;\n\n");
    }

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
    // spec-const-sized member — therefore cannot be faithfully lowered: zioshade
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
                // zioshade's SPIR-V emits it as an undecorated scalar-int Output, so
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
                    if (is_fragment) {
                        // Detect depth output. The frag_depth var is tracked
                        // ONLY in depth_output_var_id, never appended to
                        // output_vars: output_vars is the list of @location
                        // outputs the FragmentOutput struct is built from, and a
                        // depth entry in it would fabricate a @location field
                        // for a builtin. (#wgsl-cts)
                        var is_depth = false;
                        if (builtin != null) {
                            const bi: spirv.BuiltIn = @enumFromInt(builtin.?);
                            if (bi == .frag_depth) {
                                depth_output_var_id = inst.words[2];
                                is_depth = true;
                            }
                        }
                        if (!is_depth) {
                            try output_vars.append(arena, inst.words[2]);
                            if (output_var_id == null) output_var_id = inst.words[2];
                        }
                    } else {
                        try output_vars.append(arena, inst.words[2]);
                        if (is_vertex) {
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

    // External glslang vertex shaders wrap gl_Position in a member-decorated
    // `gl_PerVertex` Block (gl_Position is MEMBER 0, decorated BuiltIn Position;
    // written via OpAccessChain + OpStore) rather than a direct var-level-decorated
    // output. Detect that block here so the position output is recognized; member 0
    // becomes the `@builtin(position)` field of VertexOutput (see below). Requires
    // member 0 to actually be WRITTEN — a declared-but-unwritten block must still
    // honest-error like any vertex shader that never assigns gl_Position.
    var pervertex_var_id: ?u32 = null;
    var pervertex_struct_type: ?u32 = null;
    if (is_vertex) {
        for (output_vars.items) |ovid| {
            const sty = perVertexBlockStructType(&module, ovid) orelse continue;
            if (!perVertexMemberWritten(&module, ovid, 0)) continue;
            pervertex_var_id = ovid;
            pervertex_struct_type = sty;
            break;
        }
    }

    // WGSL requires every vertex entry to return a @builtin(position) value. A
    // vertex shader that never writes gl_Position cannot be lowered to valid
    // WGSL (naga: "Vertex shaders must return a @builtin(position) output").
    // Fabricating one would be silent-wrong, so fail loud with an honest error.
    if (is_vertex and output_vars.items.len > 0) {
        var has_position = pervertex_var_id != null;
        if (!has_position) for (output_vars.items) |ovid| {
            if (getDecVal(&decorations, ovid, .built_in)) |bv| {
                if (bv == @intFromEnum(spirv.BuiltIn.position)) {
                    has_position = true;
                    break;
                }
            }
        };
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

    // SubpassData (Vulkan input attachments): a subpassLoad lowers to OpImageRead on
    // a Dim==6 image whose coordinate is a (0,0) placeholder (Vulkan reads a subpass
    // attachment implicitly at the current fragment position). WGSL has no implicit
    // subpass read, so the OpImageRead arm (emitBody) reads at the fragment coordinate
    // (@builtin(position)). The source SPIR-V often does NOT declare gl_FragCoord
    // (subpassLoad never names it), so when a subpass read exists we resolve a
    // fragment-coordinate input here: reuse an existing BuiltIn FragCoord input when
    // the source declares one, else synthesize one. The name is threaded into
    // emitBody; if the read is inside a helper, the input is promoted to a
    // module-scope var<private> so the helper can reference it (WGSL builtins are
    // entry-param-only). (Port of MSL #488; MS subpass is honest-errored in emitBody
    // via the storageImageShape multisample guard.)
    var subpass_fragcoord_name: ?[]const u8 = null;
    if (is_fragment) {
        var subpass_found = false;
        var subpass_in_helper = false;
        {
            var cur_fn: u32 = 0;
            var in_entry = false;
            for (module.instructions) |inst| {
                if (inst.op == .Function and inst.words.len >= 3) {
                    cur_fn = inst.words[2];
                    in_entry = (module.entry_point_id != null and cur_fn == module.entry_point_id.?);
                } else if (inst.op == .FunctionEnd) {
                    cur_fn = 0;
                    in_entry = false;
                } else if (inst.op == .ImageRead and inst.words.len > 3 and imageValueDim(&module, inst.words[3]) == 6) {
                    subpass_found = true;
                    if (!in_entry) subpass_in_helper = true;
                }
            }
        }
        if (subpass_found) {
            // Reuse an existing BuiltIn FragCoord input if the source declares one.
            var fc_id: ?u32 = null;
            for (input_vars.items) |iv| {
                if (iv.builtin) |bi| {
                    if (bi == .frag_coord) {
                        fc_id = iv.id;
                        break;
                    }
                }
            }
            if (fc_id == null) {
                // Synthesize a @builtin(position) input. gl_FragCoord is always
                // vec4f, so reuse a real 32-bit-float vec4 type id from the module
                // (a fragment shader that reads a subpass attachment always has one
                // -- its color output or the ImageRead result); honest-error if not.
                // The synthesized VAR id is only ever a map key (entry-param /
                // promoted-input / names lookups) -- no consumer calls getDef on a
                // var id, only on its type id -- so a value past the real id range is
                // safe and collision-free. Take the max id-sized word as an upper
                // bound so the synthetic id never collides with a real one.
                var vec4f_type_id: ?u32 = null;
                var max_id: u32 = 0;
                for (module.instructions) |inst| {
                    for (inst.words[1..]) |word| {
                        if (word > max_id and word < 0x4000_0000) max_id = word;
                    }
                    if (vec4f_type_id == null and inst.op == .TypeVector and inst.words.len >= 4) {
                        const el = getDef(&module, inst.words[2]) orelse continue;
                        if (el.op == .TypeFloat and inst.words[3] == 4) vec4f_type_id = inst.words[1];
                    }
                }
                if (vec4f_type_id == null) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "SubpassData read but no vec4f type for the synthesized fragment coordinate", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const synth_id = max_id + 1;
                fc_id = synth_id;
                const fc_name = alloc.dupe(u8, "_fragCoord") catch return error.OutOfMemory;
                if (names.fetchPut(synth_id, fc_name) catch null) |old| alloc.free(old.value);
                try input_vars.append(arena, .{ .id = synth_id, .type_id = vec4f_type_id.?, .builtin = .frag_coord });
            }
            // Promote when a helper reads the subpass attachment, so the helper can
            // reference the (entry-param-only) builtin via its var<private> bridge.
            if (subpass_in_helper) promoted_inputs.put(fc_id.?, {}) catch {};
            subpass_fragcoord_name = names.get(fc_id.?);
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
    var cbuffers = std.ArrayList(struct { name: []const u8, type_id: u32, set: u32, binding: u32, is_ssbo: bool, is_push_constant: bool, result_id: u32, is_read_only: bool }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // `access` is the WGSL storage-texture access mode (read / write /
    // read_write) resolved from the variable's NonWritable/NonReadable
    // decorations; it is only consulted when `is_storage` is true.
    var textures = std.ArrayList(struct { name: []const u8, set: u32, binding: u32, image_type_id: u32, is_storage: bool, access: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Standalone Vulkan separate samplers (GLSL `uniform sampler uS;` — a bare
    // OpTypeSampler in UniformConstant, combined with a separate texture at each
    // `sampler2D(tex, samp)` call site). These have no implicit texture partner,
    // so unlike a combined sampler2D they were dropped here and never declared
    // (`var uS: sampler;`), leaving call args referencing an undeclared name.
    var samplers = std.ArrayList(struct { name: []const u8, set: u32, binding: u32, is_comparison: bool }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Sampler variables whose OpSampledImage results feed ONLY depth-compare
    // ops: WGSL types their binding sampler_comparison (SPIR-V samplers are
    // opaque; comparison-ness is which op samples with them). Mixed-use
    // samplers were already refused by the early guard, so dref_vars here are
    // dref-only.
    const sampler_uses_for_decl = collectSamplerUses(&module, arena);

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
                // An SSBO is flagged by `BufferBlock` on the block STRUCT. For a
                // plain block the pointee IS that struct, but for an ARRAY of
                // blocks (`buffer B { … } bufs[2];`) the pointee is OpTypeArray and
                // the decoration sits on the element struct — so unwrap array
                // levels first. Without this, an array-of-SSBO was mis-detected as
                // a read-only uniform and emitted `var<uniform>`, making a store
                // `bufs[i].x = …` a naga reject = silent-wrong. (#170)
                const is_ssbo = hasDec(&decorations, arrayElementType(&module, pointee_type), .buffer_block);
                // NonWritable (from GLSL `readonly` / WGSL `var<storage>`) marks a
                // read-only SSBO; see the .StorageBuffer arm.
                const is_read_only = is_ssbo and hasDec(&decorations, result_id, .non_writable);
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .set = set, .binding = binding, .is_ssbo = is_ssbo, .is_push_constant = false, .result_id = result_id, .is_read_only = is_read_only });
            },
            .StorageBuffer => {
                const binding = getDecVal(&decorations, result_id, .binding) orelse 0;
                const set = getDecVal(&decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "buffer";
                // SPIR-V marks a read-only storage buffer with NonWritable on the
                // VARIABLE (tint emits exactly that for WGSL `var<storage>`; glslang
                // for GLSL `readonly buffer`). WGSL's read mode `var<storage>` is the
                // faithful spelling -- and it is SEMANTICALLY load-bearing, not just
                // documentation: WGSL's uniformity analysis treats a read-only storage
                // read as uniform and a read_write one as non-uniform, so defaulting
                // everything to read_write wrongly taints subgroup-shuffle deltas and
                // broadcast ids built from buffer reads.
                const is_read_only = hasDec(&decorations, result_id, .non_writable);
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .set = set, .binding = binding, .is_ssbo = true, .is_push_constant = false, .result_id = result_id, .is_read_only = is_read_only });
            },
            .PushConstant => {
                // WGSL has NO push_constant address space (naga rejects both
                // `var<push_constant>` and `enable push_constant`). The representable
                // lowering is a plain uniform buffer. Push constants carry no
                // Binding/DescriptorSet decoration, so we INVENT a slot. With the 1:1
                // (set,binding) encoding (the silent-renumber dedup is gone), the
                // push-constant is placed AFTER the collection loop at
                // @group(max_real_set+1) @binding(0) -- a group no real descriptor
                // uses, so it never collides and its slot is deterministic (no longer
                // renumbered). Mirroring the .Uniform arm reuses all downstream
                // machinery (struct forward-decls, name-collision rename, `push.value0`
                // access chains).
                const name = names.get(result_id) orelse "push";
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .set = 0, .binding = 0, .is_ssbo = false, .is_push_constant = true, .result_id = result_id, .is_read_only = false });
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
                        try textures.append(arena, .{ .name = name, .set = set, .binding = binding, .image_type_id = img_type_id, .is_storage = false, .access = "read_write" });
                    },
                    .TypeImage => {
                        const img_dim = if (pointee_inst.words.len > 3) pointee_inst.words[3] else 1;
                        if (pointee_inst.words.len > 7 and pointee_inst.words[7] == 2) is_storage = true;
                        // readonly/writeonly come from NonWritable/NonReadable on
                        // the VARIABLE (result_id), not the image type, so the
                        // access mode is resolved here where the variable is known.
                        var access = storageAccessMode(&decorations, result_id);
                        // SubpassData (Dim 6, Vulkan input attachments) is read-only
                        // at the fragment position: WGSL has no input-attachment type,
                        // so a read-only storage texture is the closest faithful form,
                        // AND `read_write` is rejected by naga in fragment stage. Force
                        // read-only here (and read at the fragment coordinate in
                        // emitBody, port of MSL #488).
                        if (img_dim == 6) {
                            is_storage = true;
                            access = "read";
                        }
                        try textures.append(arena, .{ .name = name, .set = set, .binding = binding, .image_type_id = pointee_type, .is_storage = is_storage, .access = access });
                    },
                    .TypeSampler => {
                        try samplers.append(arena, .{
                            .name = name,
                            .set = set,
                            .binding = binding,
                            .is_comparison = sampler_uses_for_decl.dref_vars.contains(result_id),
                        });
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
        // Single-store private forwarding: the var has no module-scope life
        // left; its loads are aliased to the stored value and its store (and
        // declaration) are suppressed. Declaring it anyway would leave an
        // unused var<private> AND, worse, reintroduce the written-at-runtime
        // module-scope private that defeats tint's uniformity analysis.
        if (forward_private_stores.contains(result_id)) continue;
        const name = names.get(result_id) orelse continue;
        const rt = try wgslType(&module, inst.words[1], &names, arena);
        // Check if this Private var is actually used. A direct OpLoad reads a
        // scalar/struct global; an OpAccessChain rooted at the var reads an
        // element (`arr[i]` for a const array). Both count as "used" — missing
        // the access-chain case skipped declaring const-array globals, leaving
        // `arr[i]` referencing an undeclared name (naga reject). Safe to declare
        // now that the initializer path below emits the real array values via
        // resolveConstantExpr (not a zero-initialised var<private>).
        // A WRITE-ONLY var (OpStore, direct or through an access chain) is used
        // too: skipping its declaration left the store's target as an undeclared
        // identifier at exit 0 (naga emits this for every `var<private> x: T;`
        // that main only assigns). (#wgsl-cts)
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
            if (check.op == .Store and check.words.len >= 2) {
                if (check.words[1] == result_id) {
                    has_load = true;
                    break;
                }
                if (getDef(&module, check.words[1])) |tgt| {
                    if (tgt.op == .AccessChain and tgt.words.len > 3 and tgt.words[3] == result_id) {
                        has_load = true;
                        break;
                    }
                }
            }
        }
        if (!has_load) continue;
        // A global that is WRITTEN (an OpStore to the var, or to an AccessChain
        // rooted at it) is mutable and must be `var<private>`, never `const` —
        // WGSL rejects assignment to a `const`. A never-written global stays a
        // `const` so it inlines/folds like a compile-time constant.
        var is_written = false;
        for (module.instructions) |check| {
            if (check.op != .Store or check.words.len < 2) continue;
            if (check.words[1] == result_id) {
                is_written = true;
                break;
            }
            const tgt = getDef(&module, check.words[1]);
            if (tgt != null and tgt.?.op == .AccessChain and tgt.?.words.len > 3 and tgt.?.words[3] == result_id) {
                is_written = true;
                break;
            }
        }
        // Check for initializer (optional 5th word in OpVariable)
        if (inst.words.len > 4) {
            // Emit the real initial value. If we can't materialise the initializer,
            // DON'T fall through to a zero-initialised `var<private>` (that would be
            // the wrong values = silent-wrong) — skip the declaration so the access
            // fails loudly (naga: undefined identifier) instead of reading zeros.
            const init_id = inst.words[4];
            if (resolveConstantExpr(&module, &names, init_id, arena)) |val| {
                // #252: a non-finite float is spelled `bitcast<f32>(0x..u)` (valid in
                // runtime expressions) but naga REJECTS `bitcast` in a const-expression
                // ("Not implemented as constant expression"). WGSL has no const-expr
                // form for inf/nan, so a module-scope initializer with a non-finite
                // component is unrepresentable — fail loud, don't emit non-parsing output.
                if (std.mem.indexOf(u8, val, "bitcast<f32>(0x") != null) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot represent a non-finite float constant in a module-scope initializer", .{}) catch null;
                    return error.UnsupportedOp;
                }
                // A mutable global keeps its initializer on a `var<private>`
                // (WGSL permits a const-expression initializer there); an
                // immutable one folds as a `const`.
                if (is_written) {
                    try w.print("var<private> {s}: {s} = {s};\n", .{ name, rt, val });
                } else {
                    try w.print("const {s}: {s} = {s};\n", .{ name, rt, val });
                }
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
            const rt = try wgslType(&module, actual_type, &names, arena);
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
        const rt = try wgslType(&module, actual_type, &names, arena);
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

    // #wgsl-uniformity-8k2: the result ids of every uniformity-gated builtin
    // that sits in non-uniform control flow (see
    // computeNonuniformGatedBuiltinIds): the implicit-Lod samples AND, since
    // #685, the derivative opcodes. The emitter lowers exactly the marked
    // samples to textureSampleLevel(..., 0.0) / textureSampleCompareLevel so
    // tint/Dawn cannot reject the module, and REFUSES exactly the marked
    // derivatives (a derivative has no lowered form to downgrade to).
    const nonuniform_gated = try computeNonuniformGatedBuiltinIds(arena, &module, &decorations);

    // #170: an SSBO that is an ARRAY of blocks whose struct holds a runtime-sized
    // array (`buffer SSBO { vec4 data[]; } ssbos[2];`) has no core-WGSL form —
    // a runtime array can't nest inside a fixed array (naga "Base type for the
    // array is invalid"). zioshade emitted `var<storage> ssbos: array<SSBO, 2>` =
    // silent-wrong. Honest-error rather than emit naga-rejected WGSL.
    for (cbuffers.items) |cb| {
        if (!cb.is_ssbo) continue;
        if (ssboArrayOfRuntimeArrayStruct(&module, cb.type_id)) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL cannot express an array of storage blocks with a runtime-sized array member (array<SSBO, N> with a runtime array nested inside)", .{}) catch null;
            return error.UnsupportedOp;
        }
    }

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
        // #170: a uniform/push-constant block with a sub-16-stride array member
        // (std430/scalar layout, e.g. `float Arr[4]`) is unrepresentable in core
        // WGSL uniform space — it can't be widened without reading wrong data and
        // emitting it as `var<uniform>` is naga-rejected ("array stride N not a
        // multiple of 16") at exit 0 = silent-wrong. Honest-error instead.
        if (uniformBlockHasUnrepresentableSub16Array(&module, struct_id)) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "std430/scalar-layout uniform or push-constant block has a sub-16-byte array stride that WGSL uniform space cannot represent (it requires a multiple of 16)", .{}) catch null;
            return error.UnsupportedOp;
        }
        collectWrappedUniformMembersForStruct(&module, struct_id, &wrapped_uniform_members) catch {};
    }
    // Empty wrap-map for NON-uniform struct emission (local/function/workgroup
    // structs are not in uniform space, so their array members are never wrapped).
    var no_wrapped_members = WrappedUniformMemberMap.init(arena);
    defer no_wrapped_members.deinit();

    // #170: the set of struct type ids reachable from a UNIFORM block (its pointee
    // struct + nested struct members). emitOneStructForwardDecl reproduces these
    // structs' SPIR-V member byte offsets via @align/@size so naga's uniform
    // address-space layout matches the host's std140 packing. The SAME set is
    // passed to every struct-emit call site — only uniform-reachable structs are
    // members, so non-uniform structs skip the attribute pass and stay byte-identical.
    // SSBO-only structs are NOT marked (storage tolerates the natural sub-16 layout).
    var uniform_offset_structs = std.AutoHashMap(u32, void).init(arena);
    defer uniform_offset_structs.deinit();
    for (cbuffers.items) |cb| {
        if (cb.is_ssbo) continue;
        var struct_id = cb.type_id;
        if (getDef(&module, struct_id)) |pi| {
            if (pi.op == .TypePointer and pi.words.len > 3) struct_id = pi.words[3];
        }
        collectOffsetStructsRec(&module, struct_id, &uniform_offset_structs, 0);
    }

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
        try emitStructForwardDecls(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &wrapped_uniform_members, &uniform_offset_structs);
        try emitOneStructForwardDecl(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &wrapped_uniform_members, &uniform_offset_structs);
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
                                try emitOneStructForwardDecl(&module, &names, tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
                            }
                        }
                    }
                }
            }
        }
        // A struct used only as an SSA VALUE (no OpVariable) — e.g. `S s = S(1.0,
        // 2.0);` constant-folds to an OpCompositeConstruct whose result type is the
        // struct — is otherwise never collected, so `S` was referenced but never
        // declared (naga "no definition in scope"). Collect the struct (and its
        // nested structs) from the result type of value-producing ops.
        switch (inst.op) {
            .CompositeConstruct, .CompositeExtract, .Load, .FunctionCall, .Phi, .Select, .CopyObject, .ConstantComposite, .SpecConstantComposite => {
                if (inst.words.len >= 2) {
                    var tid = inst.words[1];
                    while (getDef(&module, tid)) |ti| {
                        if (ti.op == .TypePointer and ti.words.len > 3) {
                            tid = ti.words[3];
                        } else if ((ti.op == .TypeArray or ti.op == .TypeRuntimeArray) and ti.words.len > 2) {
                            tid = ti.words[2];
                        } else break;
                    }
                    const ti = getDef(&module, tid);
                    if (ti != null and ti.?.op == .TypeStruct and local_structs.get(tid) == null) {
                        local_structs.put(tid, {}) catch {};
                        try emitStructForwardDecls(&module, &names, tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
                        try emitOneStructForwardDecl(&module, &names, tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
                    }
                }
            },
            else => {},
        }
    }

    // Place invented push-constant buffers (WGSL has no push_constant address space;
    // zioshade lowers them to a uniform buffer with an invented slot) at a dedicated
    // @group no real descriptor uses, so the slot is deterministic and never collides.
    // The old code used a silent-renumber dedup across ALL cbuffers, which made the WGSL
    // @binding NOT match the host's set/binding intent -- a silent miscompile for set>=2
    // ((set=0,binding=N+1) and (set=2,binding=N) collided). Real descriptors now keep their
    // 1:1 (set,binding); only the invented push-constant gets a synthesized group.
    {
        var max_set: u32 = 0;
        for (cbuffers.items) |cb| {
            if (!cb.is_push_constant) max_set = @max(max_set, cb.set);
        }
        for (textures.items) |tex| max_set = @max(max_set, tex.set);
        for (samplers.items) |samp| max_set = @max(max_set, samp.set);
        for (cbuffers.items) |*cb| {
            if (cb.is_push_constant) cb.set = max_set + 1;
        }
    }

    // Under the 1:1 (set,binding) encoding, real SPIR-V descriptors each have a unique
    // slot, so they never collide. A duplicate @group/@binding here means the INPUT
    // itself collides -- e.g. a loose uniform (no layout(binding=), defaults to 0)
    // synthesized into the _Globals block colliding with an explicit-binding resource,
    // or two resources at the same (set,binding). WGSL requires a unique @group/@binding
    // per var, so this is unrepresentable: honest-error rather than emit invalid WGSL
    // (a duplicate @binding naga rejects). (The old binding*2+set dedup silently
    // renumbered these -> @binding no longer matched host intent, a silent miscompile.)
    {
        var seen_slots = std.AutoHashMap(u64, void).init(arena);
        const dup = blk: {
            for (cbuffers.items) |cb| {
                const b = common.applyBindingShift(cb.binding, options.binding_shift);
                const key = (@as(u64, cb.set) << 32) | @as(u64, b);
                if (seen_slots.contains(key)) break :blk true;
                seen_slots.put(key, {}) catch {};
            }
            for (textures.items) |tex| {
                const b = common.applyBindingShift(tex.binding, options.binding_shift);
                const key = (@as(u64, tex.set) << 32) | @as(u64, b);
                if (seen_slots.contains(key)) break :blk true;
                seen_slots.put(key, {}) catch {};
            }
            for (samplers.items) |samp| {
                const b = common.applyBindingShift(samp.binding, options.binding_shift);
                const key = (@as(u64, samp.set) << 32) | @as(u64, b);
                if (seen_slots.contains(key)) break :blk true;
                seen_slots.put(key, {}) catch {};
            }
            break :blk false;
        };
        if (dup) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL requires a unique @group/@binding per resource; the input has descriptors that collide under the 1:1 (set,binding) map (e.g. a loose uniform without layout(binding=) or an explicit duplicate binding)", .{}) catch null;
            return error.UnsupportedOp;
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
        const group = cb.set;
        const binding = common.applyBindingShift(cb.binding, options.binding_shift);
        const type_name = blk: {
            // Resolve pointer type to pointee type
            const ptr_inst = getDef(&module, cb.type_id);
            const actual_type = if (ptr_inst) |pi|
                if (pi.op == .TypePointer and pi.words.len > 3) pi.words[3] else cb.type_id
            else
                cb.type_id;
            break :blk try wgslType(&module, actual_type, &names, arena);
        };
        // Anonymous block (`buffer B { … };` with no instance name): glslang names the
        // block TYPE but emits an EMPTY OpName for the variable, so `cb.name` is "" (not
        // null — the `orelse` fallback never fired). That produced an invalid
        // `var<storage> : T;` (naga: "expected identifier") and base-less member
        // accesses (`.d[0]`). Synthesize a name from the block type and register it in
        // `names` so the declaration AND the access chains (emitted later) both use it. (#170)
        var var_name: []const u8 = cb.name;
        if (var_name.len == 0) {
            // Pick `{type}_buf`, bumping a numeric suffix until it collides with no
            // other variable name — so two anonymous blocks, or a user variable that
            // happens to be named `{type}_buf`, cannot produce a duplicate WGSL
            // identifier (naga "redefinition"). (#170)
            var counter: u32 = 0;
            var synth = try std.fmt.allocPrint(alloc, "{s}_buf", .{type_name});
            while (nameInUse(&names, synth, cb.result_id)) {
                alloc.free(synth);
                counter += 1;
                synth = try std.fmt.allocPrint(alloc, "{s}_buf_{d}", .{ type_name, counter });
            }
            if (try names.fetchPut(cb.result_id, synth)) |old| alloc.free(old.value);
            var_name = synth;
        }
        // Avoid name collision: if variable name same as type name, rename the variable
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
        else
            cb.type_id;
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
            // Struct/aggregate-element array (e.g. an array of UBO blocks): wrap in
            // a `values` field for the same WGSL uniform-array stride reason, and —
            // (Also reached if a float/int array's element count could not be
            // decoded above — e.g. a spec-constant size — in which case the `.x`
            // scalar-widening the float/int path would add is absent; that narrow
            // spec-const-sized-uniform-array case is a separate pre-existing gap.)
            // like the float/int path above — remap the base name so every access
            // chain goes through the wrapper field (`us[i].x` → `us.values[i].x`).
            // Without the remap the body emits `us[i].member`, which naga rejects
            // ("invalid field accessor"). No `.x` suffix here (no scalar widening).
            try w.print("struct {s}_wrapper {{ values: {s} }};\n\n", .{ var_name, type_name });
            try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: {s}_wrapper;\n\n", .{ group, binding, var_name, var_name });
            for (module.instructions) |vinst| {
                if (vinst.op == .Variable and vinst.words.len >= 4) {
                    const vname = names.get(vinst.words[2]) orelse continue;
                    if (std.mem.eql(u8, vname, var_name)) {
                        const wrapper_name = try std.fmt.allocPrint(alloc, "{s}.values", .{var_name});
                        if (try names.fetchPut(vinst.words[2], wrapper_name)) |old| alloc.free(old.value);
                        break;
                    }
                }
            }
        } else if (cb.is_ssbo) {
            // Read mode for a NonWritable buffer (see the .StorageBuffer arm);
            // read_write otherwise. Plain `var<storage>` IS the read mode in
            // WGSL (the default access for storage when omitted).
            if (cb.is_read_only) {
                try w.print("@group({d}) @binding({d})\nvar<storage> {s}: {s};\n\n", .{ group, binding, var_name, type_name });
            } else {
                try w.print("@group({d}) @binding({d})\nvar<storage, read_write> {s}: {s};\n\n", .{ group, binding, var_name, type_name });
            }
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
                        try emitOneStructForwardDecl(&module, &names, pointee_type, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
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

    // Emit textures and samplers. Group sampler + texture pairs.
    // 1:1 (set,binding) -> @group=set, @binding=binding. binding_shift applies to
    // @binding only; @group is the SPIR-V descriptor set. Real descriptors (cbuffers,
    // textures, standalone samplers) keep their 1:1 (set,binding) and never collide
    // (SPIR-V gives each a unique slot). A combined sampler2D's paired SAMPLER is an
    // INVENTED resource (no SPIR-V binding): under 1:1 its natural binding+1 can collide
    // with the next texture (two adjacent sampler2D at binding 0,1), so place each
    // invented sampler at the first free binding in its set -- neither silently renumbering
    // real descriptors (the old dedup's silent miscompile) nor leaving a duplicate @binding
    // (a loud reject for a COMMON multi-texture shader).
    var sampler_names = std.ArrayList(struct { name: []const u8, binding: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    const SlotKey = struct { set: u32, binding: u32 };
    var used_slots = std.AutoHashMap(SlotKey, void).init(arena);
    for (cbuffers.items) |cb| {
        if (!cb.is_push_constant) used_slots.put(.{ .set = cb.set, .binding = cb.binding }, {}) catch {};
    }
    for (textures.items) |tex| used_slots.put(.{ .set = tex.set, .binding = tex.binding }, {}) catch {};
    for (samplers.items) |samp| used_slots.put(.{ .set = samp.set, .binding = samp.binding }, {}) catch {};

    for (textures.items) |tex| {
        const group = tex.set;
        const binding = common.applyBindingShift(tex.binding, options.binding_shift);
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
            // First free binding in this set for the invented paired sampler.
            var sb: u32 = tex.binding + 1;
            while (used_slots.contains(.{ .set = tex.set, .binding = sb })) : (sb += 1) {}
            used_slots.put(.{ .set = tex.set, .binding = sb }, {}) catch {};
            try sampler_names.append(arena, .{ .name = sampler_name, .binding = sb });
            const sampler_binding = common.applyBindingShift(sb, options.binding_shift);
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n\n", .{ group, sampler_binding, sampler_name, sampler_kind });
        }
    }

    // Emit standalone Vulkan separate samplers (`var uS: sampler;`). Each is
    // combined with a texture at the `sampler2D(tex, samp)` call site, where the
    // sample handlers resolve the sampler argument from the OpSampledImage's
    // sampler operand (see resolveSamplerArg). 1:1 (set,binding) -> @group=set,
    // @binding=binding.
    for (samplers.items) |samp| {
        const group = samp.set;
        const binding = common.applyBindingShift(samp.binding, options.binding_shift);
        // A sampler whose only sampled-image uses are depth-compare ops is the
        // binding WGSL must type sampler_comparison (the SPIR-V form of a
        // comparison sampler: a sampler2DShadow call site). A plain `sampler`
        // here makes every textureSampleCompare/textureGatherCompare call on it
        // a naga reject ("Comparison sampling mismatch"): the silent-wrong
        // class this typing prevents.
        const kind: []const u8 = if (samp.is_comparison) "sampler_comparison" else "sampler";
        try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n\n", .{ group, binding, samp.name, kind });
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
    // M3.5: emit OpSpecConstantOp as a derived `override` expression. A spec-
    // constant-op result derives from a specialization constant (`override`),
    // and WGSL forbids a `const` from referencing an `override` (naga:
    // "Unexpected override-expression"), so the derived value must itself be an
    // `override`: `override NAME: T = LEAF * 2;` re-evaluates at pipeline-
    // creation time when the user supplies an override for LEAF.
    var sc_op_emitted_any = false;
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantOp or inst.words.len < 6) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try wgslType(&module, type_id, &names, arena);
        // OpSelect (ternary, 7 words). WGSL has no `?:`; OpSelect's operands
        // are [cond, true, false] and WGSL select is select(false, true, cond).
        // (#499 -- spec-constant ternary over a spec constant.)
        if (opcode_lit == 169 and inst.words.len == 7) {
            const cond = names.get(inst.words[4]) orelse continue;
            const tv = names.get(inst.words[5]) orelse continue;
            const fv = names.get(inst.words[6]) orelse continue;
            try w.print("override {s}: {s} = select({s}, {s}, {s});\n", .{ name, type_str, fv, tv, cond });
            sc_op_emitted_any = true;
            continue;
        }
        const op_str: ?[]const u8 = switch (opcode_lit) {
            128, 129 => @as([]const u8, "+"),
            130, 131 => @as([]const u8, "-"),
            132, 133 => @as([]const u8, "*"),
            134, 135, 136 => @as([]const u8, "/"),
            // #499: integer/float comparisons (result type is bool).
            170, 180, 181 => @as([]const u8, "=="),
            171, 182, 183 => @as([]const u8, "!="),
            172, 173, 186, 187 => @as([]const u8, ">"),
            174, 175, 190, 191 => @as([]const u8, ">="),
            176, 177, 184, 185 => @as([]const u8, "<"),
            178, 179, 188, 189 => @as([]const u8, "<="),
            else => null,
        };
        const op = op_str orelse continue;
        if (inst.words.len != 6) continue;
        const op0 = names.get(inst.words[4]) orelse continue;
        const op1 = names.get(inst.words[5]) orelse continue;
        try w.print("override {s}: {s} = {s} {s} {s};\n", .{ name, type_str, op0, op, op1 });
        sc_op_emitted_any = true;
    }
    if (sc_emitted_any or sc_composite_emitted_any or sc_op_emitted_any) try w.writeAll("\n");

    // Emit non-entry functions first
    var func_ids = std.ArrayList(u32).initCapacity(arena, 8) catch return error.OutOfMemory;
    var func_idx_map = std.AutoHashMap(u32, usize).init(arena);
    for (module.instructions, 0..) |inst, i| {
        if (inst.op == .Function and inst.words.len > 2) {
            // append (not appendAssumeCapacity): a module with more than the initial
            // capacity of functions (entry + >8 helpers) would otherwise overflow the
            // assumed capacity and panic. Grow instead. (#170 no-panic.)
            try func_ids.append(arena, inst.words[2]);
            func_idx_map.put(inst.words[2], i) catch {};
        }
    }
    // Prune functions UNREACHABLE from the selected entry point. A multi-entry
    // module (naga lowers every WGSL entry point to its own OpEntryPoint) also
    // carries the UNSELECTED entries' bodies, and their Output stores have no
    // WGSL home: only the selected entry gets the output-variable
    // reconstruction. Emitting those bodies referenced Output variables nothing
    // declared, leaving undeclared identifiers at exit 0. Pruning mirrors how
    // the module is actually consumed (one entry per compile). (#wgsl-cts)
    if (module.entry_point_id) |ep_id| {
        var reachable = std.AutoHashMap(u32, void).init(arena);
        var work = std.ArrayList(u32).initCapacity(arena, 8) catch return error.OutOfMemory;
        try work.append(arena, ep_id);
        try reachable.put(ep_id, {});
        var wi: usize = 0;
        while (wi < work.items.len) : (wi += 1) {
            const fidx = func_idx_map.get(work.items[wi]) orelse continue;
            var si: usize = fidx + 1;
            while (si < module.instructions.len) : (si += 1) {
                const ci = module.instructions[si];
                if (ci.op == .FunctionEnd) break;
                if (ci.op == .FunctionCall and ci.words.len > 3) {
                    const callee = ci.words[3];
                    if (!reachable.contains(callee)) {
                        try reachable.put(callee, {});
                        try work.append(arena, callee);
                    }
                }
            }
        }
        var pruned = std.ArrayList(u32).initCapacity(arena, func_ids.items.len) catch return error.OutOfMemory;
        for (func_ids.items) |fid| {
            if (reachable.contains(fid)) try pruned.append(arena, fid);
        }
        func_ids = pruned;
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
                    try emitOneStructForwardDecl(&module, &names, fti.words[2], w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
                    // Also emit for param types
                    for (fti.words[3..]) |param_tid| {
                        try emitOneStructForwardDecl(&module, &names, param_tid, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
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
                    try emitOneStructForwardDecl(&module, &names, type_id, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
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
                        for (module.instructions[fidx + 1 ..]) |pinst| {
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

        // Conservative inout split. The single-inout-void return-value idiom
        // (signature returns the pointee; body returns the local copy; caller
        // reassigns) is proven faithful, so it is left UNCHANGED. Only route
        // MULTI-pointer-param (>=2) or NON-void + pointer-param functions
        // through real WGSL ptr<function> params. For those, the old lowering
        // emitted value params + a local copy, so inout writes died in the copy
        // and never reached the caller (e.g. particle_sim dropped every
        // updateParticle mutation). The pointer routes every OpLoad/OpStore/
        // AccessChain on the param through the pointer with no hot-path edits.
        const use_ptr_inout = has_pointer_params and
            !(inout_params.items.len == 1 and std.mem.eql(u8, ret_type, "void"));

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
            for (module.instructions[fidx + 1 ..]) |pinst| {
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
            if (use_ptr_inout and is_inout) {
                // Real WGSL pointer param: inout writes reach the caller's
                // storage directly (naga accepts ptr<function, T>). The body
                // dereferences via the names-map remap below.
                try w.print("{s}: ptr<function, {s}>", .{ p_name, pt });
            } else {
                try w.print("{s}: {s}", .{ p_name, pt });
            }
            param_count += 1;
        }

        // Determine return type
        if (use_ptr_inout) {
            // Pointer params propagate inout writes themselves; use the
            // function's real return type (no synthesized return-value trick).
            if (std.mem.eql(u8, ret_type, "void")) {
                try w.writeAll(") {\n");
            } else {
                try w.print(") -> {s} {{\n", .{ret_type});
            }
        } else if (has_pointer_params and inout_params.items.len > 0) {
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

        // Emit local var declarations for inout params (single-inout-void path
        // only; ptr<function> params need no local copy -- the body mutates the
        // caller's storage through the pointer directly).
        if (!use_ptr_inout) {
            for (inout_params.items) |ip| {
                const pt = try wgslType(&module, ip.pointee_type_id, &names, arena);
                const orig_name = names.get(ip.param_id) orelse "";
                try writeIndentStatic(w, 1);
                try w.print("var {s}: {s} = {s};\n", .{ ip.local_name, pt, if (orig_name.len > 0) orig_name else "0" });
            }
        }

        // Remap pointer param IDs to local var names in the names map
        // Save old names to restore later (in case of shared IDs). The save
        // must DUPE the string: the fetchPut below frees the displaced value,
        // which is the very allocation a borrowed slice would point at, and
        // the deferred restore would then read freed memory (a latent UAF
        // that any heap-layout shift can turn into a segfault).
        var saved_names = std.ArrayList(struct { id: u32, name: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
        for (inout_params.items) |ip| {
            const old_name = names.get(ip.param_id);
            if (old_name) |n| {
                try saved_names.append(arena, .{ .id = ip.param_id, .name = try alloc.dupe(u8, n) });
            }
            // ptr<function> path: map the param id to (*name) so every OpLoad/
            // OpStore/AccessChain on it dereferences the pointer (no hot-path
            // edits). Single-inout-void path keeps the local-copy name.
            const mapped = if (use_ptr_inout) blk: {
                const pn = names.get(ip.param_id) orelse ip.local_name;
                break :blk try std.fmt.allocPrint(alloc, "(*{s})", .{pn});
            } else try alloc.dupe(u8, ip.local_name);
            if (try names.fetchPut(ip.param_id, mapped)) |old| alloc.free(old.value);
        }
        defer {
            // Restore original names. sn.name is an alloc-owned copy: its
            // ownership transfers into the names map here (fetchPut frees the
            // displaced mapping, never the saved copy).
            for (saved_names.items) |sn| {
                if (names.fetchPut(sn.id, sn.name) catch null) |old| alloc.free(old.value);
            }
        }

        const inout_ret_name: ?[]const u8 = if (!use_ptr_inout and has_pointer_params and inout_params.items.len == 1 and std.mem.eql(u8, ret_type, "void")) inout_params.items[0].local_name else null;
        try emitBody(&module, &names, &decorations, fidx, w, alloc, arena, inout_ret_name, null, null, &wrapped_uniform_arrays, &wrapped_uniform_members, &matrix_outputs, &atomic_vars, &atomic_fields, &nonuniform_gated, .none, subpass_fragcoord_name, null, null);

        try w.writeAll("}\n\n");
    }

    // Emit VertexOutput struct if vertex shader has multiple outputs
    var vertex_output_fields = std.ArrayList(struct { name: []const u8, type_name: []const u8, builtin: ?[]const u8, location: ?u32, flat: bool, linear: bool, interp_sample: []const u8 = "" }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Detect depth output for fragment shaders
    var use_frag_depth_struct = false;
    var use_frag_mrt_struct = false;
    // The @location field text shared by the MRT struct and the depth struct
    // (the depth var itself is excluded from output_vars at collection, so
    // these fields are exactly the shader's color outputs).
    var frag_loc_fields = std.ArrayList(u8).initCapacity(arena, 128) catch return error.OutOfMemory;
    if (is_fragment and (depth_output_var_id != null or output_vars.items.len > 1)) {
        // Two outputs sharing a @location is GLSL dual-source blending
        // (`layout(location=0, index=0/1)`), which WGSL expresses with
        // `@blend_src(0/1)`. zioshade's SPIR-V currently drops the `Index`
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
        // The field type is the output variable's REAL pointee type: a hardcoded
        // `vec4f` matched the common GLSL MRT shape, but a scalar/other-typed
        // output (a WGSL-authored `@location(n) out: f32`) then got a `vec4f`
        // field that the synthesized `FragmentOutput(<captured scalar>)` return
        // could never satisfy (naga: automatic-conversion reject). (#wgsl-cts)
        for (output_vars.items, 0..) |ovid, i| {
            const loc = getDecVal(&decorations, ovid, .location) orelse i;
            const var_name = names.get(ovid) orelse continue;
            var field_type: []const u8 = "vec4f";
            if (getDef(&module, ovid)) |ovi| {
                if (ovi.words.len > 1) {
                    var pt = ovi.words[1];
                    if (getDef(&module, pt)) |pi| {
                        if (pi.op == .TypePointer and pi.words.len > 3) pt = pi.words[3];
                    }
                    field_type = try wgslType(&module, pt, &names, arena);
                }
            }
            frag_loc_fields.print(arena, "    @location({d}) {s}: {s},\n", .{ loc, var_name, field_type }) catch return error.OutOfMemory;
        }
    }
    if (is_fragment and depth_output_var_id != null) {
        // A depth-only fragment (no @location output at all; naga emits this for
        // `fn main() -> @builtin(frag_depth) f32`) must NOT get a fabricated
        // `@location(0) color: vec4f` field: that invents an output the shader
        // never had, and no captured value can fill it. Emit the depth field
        // alone; the return then takes exactly one argument. (#wgsl-cts)
        //
        // WITH @location outputs the fields are the REAL outputs (their own
        // locations and types): the old shape fabricated `@location(0) color:
        // vec4f` whenever any location output existed, so scalar / non-zero-
        // location outputs (a WGSL io-struct return lowered by naga to one
        // Output var per member) were dropped from the struct while their
        // OpStores still emitted against undeclared names at exit 0, and the
        // fabricated field invented a location and type the shader never had.
        // The location outputs then also ride the MRT capture machinery so
        // their stored values reach the return. (#wgsl-cts)
        try w.writeAll("struct FragmentOutput {\n");
        try w.writeAll(frag_loc_fields.items);
        try w.writeAll("    @builtin(frag_depth) depth: f32,\n");
        try w.writeAll("}\n\n");
        use_frag_depth_struct = true;
        if (output_vars.items.len >= 1) use_frag_mrt_struct = true;
    } else if (is_fragment and output_vars.items.len > 1) {
        // Multiple render targets: emit FragmentOutput struct.
        try w.writeAll("struct FragmentOutput {\n");
        try w.writeAll(frag_loc_fields.items);
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
    if (is_vertex and (output_vars.items.len > 1 or pervertex_var_id != null)) {
        for (output_vars.items) |ovid| {
            // glslang's gl_PerVertex block: member 0 (Position) → the
            // `@builtin(position)` field; the body's `OpAccessChain <var> 0` store
            // resolves to `vertex_out.gl_Position` via the io_block alias below.
            // gl_PointSize/gl_ClipDistance/gl_CullDistance (members 1/2/3) have no
            // WGSL vertex output, so writing any of them is an honest error rather
            // than a silent drop. Unwritten members are ignored (the common case).
            if (pervertex_var_id != null and ovid == pervertex_var_id.?) {
                const sty = pervertex_struct_type.?;
                const sdef = getDef(&module, sty) orelse continue;
                const member_count: u32 = @intCast(sdef.words.len - 2);
                var mi: u32 = 1;
                while (mi < member_count) : (mi += 1) {
                    if (!perVertexMemberWritten(&module, ovid, mi)) continue;
                    const bi = memberBuiltin(&module, sty, mi);
                    // No @tagName on the non-exhaustive BuiltIn enum — an unknown
                    // value would panic (#310). Map only the known gl_PerVertex
                    // members; anything else gets a generic name.
                    const bname: []const u8 = if (bi) |b| switch (b) {
                        .point_size => "gl_PointSize",
                        .clip_distance => "gl_ClipDistance",
                        .cull_distance => "gl_CullDistance",
                        else => "member",
                    } else "member";
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no vertex output for gl_PerVertex.{s} (point size / clip / cull distance)", .{bname}) catch null;
                    return error.UnsupportedOp;
                }
                var mb0: [32]u8 = undefined;
                const mname0 = getMemberName(&module, sty, 0, &mb0);
                const m0type = try wgslType(&module, sdef.words[2], &names, arena);
                try vertex_output_fields.append(arena, .{ .name = try arena.dupe(u8, mname0), .type_name = m0type, .builtin = "position", .location = null, .flat = false, .linear = false });
                try io_block_outputs.put(ovid, {});
                continue;
            }
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
                        try vertex_output_fields.append(arena, .{ .name = leaf.flat_name, .type_name = leaf.type_name, .builtin = null, .location = base + @as(u32, @intCast(li)), .flat = leaf.is_int, .linear = false });
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
                    const mlinear = memberHasNoPerspective(&module, actual_type, @intCast(mi));
                    try vertex_output_fields.append(arena, .{ .name = try arena.dupe(u8, mname), .type_name = mtype, .builtin = null, .location = base + @as(u32, @intCast(mi)), .flat = mflat, .linear = mlinear });
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
                            try vertex_output_fields.append(arena, .{ .name = fname, .type_name = col_type, .builtin = null, .location = base + c, .flat = false, .linear = false });
                        }
                        try matrix_outputs.put(ovid, .{ .base_name = try arena.dupe(u8, var_name), .cols = cols, .col_type = col_type });
                        continue;
                    }
                    // WGSL entry-point IO may only be numeric scalars/vectors — an
                    // array at a @location is rejected by naga ("Only numeric scalars
                    // and vectors are allowed"). The matrix arm above flattens matNxM
                    // into column @locations, but a top-level array varying is not
                    // reconstructed; emitting `@location(N) a: array<...>` would be
                    // silent-wrong. This is the OUTPUT symmetry of the array-input
                    // guard (~4120) and the matrix-MEMBER guards. (#170)
                    if (mdef.op == .TypeArray or mdef.op == .TypeRuntimeArray) {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL stage IO must be a scalar/vector: array output at @location({d}) is not supported", .{loc_val orelse 0}) catch null;
                        return error.UnsupportedOp;
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
            const needs_linear = bi_name == null and !needs_flat and
                hasDec(&decorations, ovid, .no_perspective);
            // #475: centroid/sample become the second @interpolate arg.
            const interp_sample: []const u8 = if (bi_name == null and hasDec(&decorations, ovid, .sample))
                ", sample"
            else if (bi_name == null and hasDec(&decorations, ovid, .centroid))
                ", centroid"
            else
                "";
            try vertex_output_fields.append(arena, .{
                .name = var_name,
                .type_name = type_name,
                .builtin = bi_name,
                .location = loc_val,
                .flat = needs_flat,
                .linear = needs_linear,
                .interp_sample = interp_sample,
            });
        }
    }

    // Build VertexOutput when there are 2+ outputs, OR for a gl_PerVertex block
    // even with only gl_Position written (a single `@builtin(position)` field is a
    // valid VertexOutput — the body stores through `vertex_out.gl_Position`).
    if (vertex_output_fields.items.len > 1 or pervertex_var_id != null) {
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
            const interp: []const u8 = if (field.flat) blk: {
                break :blk if (field.interp_sample.len > 0)
                    std.fmt.allocPrint(arena, "@interpolate(flat{s}) ", .{field.interp_sample}) catch "@interpolate(flat) "
                else
                    "@interpolate(flat) ";
            } else if (field.linear) blk: {
                break :blk if (field.interp_sample.len > 0)
                    std.fmt.allocPrint(arena, "@interpolate(linear{s}) ", .{field.interp_sample}) catch "@interpolate(linear) "
                else
                    "@interpolate(linear) ";
            } else if (field.interp_sample.len > 0) blk: {
                break :blk std.fmt.allocPrint(arena, "@interpolate(perspective{s}) ", .{field.interp_sample}) catch "";
            } else "";
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
            try emitStructForwardDecls(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
            try emitOneStructForwardDecl(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
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
            // signal — zioshade's SPIR-V does not emit the `Block` decoration.
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
                try emitOneStructForwardDecl(&module, &names, sty, w, arena, &emitted_structs, &emitted_names, &atomic_fields, &no_wrapped_members, &uniform_offset_structs);
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
                const linear = memberHasNoPerspective(&module, sty, @intCast(mi));
                const interp: []const u8 = if (flat) "@interpolate(flat) " else if (linear) "@interpolate(linear) " else "";
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
        try w.print("@compute @workgroup_size({d}, {d}, {d})\nfn main(", .{ ls[0], ls[1], ls[2] });
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
    // at location N are present"). zioshade does not reconstruct component packing,
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
            // Subgroup @builtins are compute/fragment only in WGSL (tint:
            // "built-in cannot be used by vertex pipeline stage"). Mapping one
            // for another stage would emit oracle-rejected output, so fail loud.
            if (builtInNeedsSubgroupsEnable(bi) and !(is_compute or is_fragment)) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL subgroup builtins are compute/fragment only ({s})", .{std.enums.tagName(spirv.BuiltIn, bi) orelse "subgroup"}) catch null;
                return error.UnsupportedOp;
            }
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
                // gl_PrimitiveID has NO core-WGSL fragment-input builtin (naga:
                // "unknown builtin: primitive_id"). It falls to the honest-error else
                // arm rather than emitting an invalid `@builtin(primitive_id)`. (#170)
                .sample_id => "sample_index",
                // SPIR-V SubgroupSize/SubgroupLocalInvocationId (SPV subgroup
                // builtins, core since 1.3). WGSL spells them subgroup_size /
                // subgroup_invocation_id under `enable subgroups;` (emitted by
                // the pre-scan when any subgroup feature is used). Both are u32
                // in WGSL and uint in SPIR-V, so no sign bridge is needed. The
                // remaining subgroup builtins (masks, NumSubgroups, SubgroupID)
                // have NO WGSL spelling and refuse in the else arm above.
                .subgroup_size => "subgroup_size",
                .subgroup_local_invocation_id => "subgroup_invocation_id",
                else => {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no @builtin for input '{s}'", .{std.enums.tagName(spirv.BuiltIn, bi) orelse "unknown"}) catch null;
                    return error.UnsupportedOp;
                },
            };
            const needs_u32 = switch (bi) {
                // WGSL requires these built-ins to be u32, but their GLSL counterparts
                // are signed int (gl_VertexID/gl_VertexIndex, gl_InstanceID/
                // gl_InstanceIndex, gl_SampleID). The coercion below declares the entry
                // param u32 and bridges to the signed name for the body. (sample_index:
                // naga rejects an i32 param — "Built-in type for SampleIndex invalid".) (#170)
                .vertex_id, .instance_id, .vertex_index, .instance_index, .sample_id => true,
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
            // WGSL entry-point IO may only be numeric scalars/vectors — a matrix or
            // array at a @location is rejected by naga ("Only numeric scalars and
            // vectors are allowed"). spirv-cross flattens a matrix/array varying into
            // N column/element @locations; zioshade does not reconstruct that, and its
            // sibling guards already honest-error on a matrix/array MEMBER at a
            // @location (see emitFlattenedLeafParams), so a top-level matrix/array
            // input must fail loud too rather than emit a silently-invalid signature. (#170)
            if (getDef(&module, actual_type)) |td| switch (td.op) {
                .TypeMatrix, .TypeArray, .TypeRuntimeArray => {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL stage IO must be a scalar/vector: matrix/array input at @location({d}) is not supported", .{loc}) catch null;
                    return error.UnsupportedOp;
                },
                else => {},
            };
            // Fragment INPUTS that are integer-typed (or GLSL `flat`-qualified)
            // need @interpolate(flat); NoPerspective needs @interpolate(linear).
            // Vertex inputs are attributes (fetched, not interpolated), so the
            // attribute is illegal there — guard on stage. (#475)
            const interp: []const u8 = blk: {
                if (is_fragment and (hasDec(&decorations, iv.id, .flat) or isIntegerWgslType(type_name)))
                    break :blk "@interpolate(flat) ";
                if (is_fragment and hasDec(&decorations, iv.id, .no_perspective))
                    break :blk "@interpolate(linear) ";
                break :blk "";
            };
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
            // On hostile SPIR-V the output variable's definition may be absent, or
            // present without a type operand — never `.?`/index it blindly (that
            // was a null-deref crash). Fall back to treating `ov` itself as the
            // type id, matching the other malformed-input branches below.
            const ov_def = getDef(&module, ov);
            const ptr_inst = if (ov_def != null and ov_def.?.words.len > 1)
                getDef(&module, ov_def.?.words[1])
            else
                null;
            var actual_type: u32 = undefined;
            if (ptr_inst) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3] else actual_type = ov;
            } else actual_type = ov;
            // An array fragment output (`out vec4 col[N]` — MRT via an array) must NOT
            // be emitted as `-> @location(0) array<…>`: naga rejects array stage IO
            // ("Only numeric scalars and vectors are allowed"). WGSL needs per-element
            // @location struct members, which this single-output path does not
            // reconstruct, so honest-error rather than emit naga-rejected WGSL — the
            // return-type symmetry of the array-input / array-member-output guards (#170).
            if (getDef(&module, actual_type)) |at_def| {
                if (at_def.op == .TypeArray or at_def.op == .TypeRuntimeArray) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL stage IO must be a scalar/vector: array fragment output (MRT via `out vec4 col[N]`) is not supported — use separate `out` variables", .{}) catch null;
                    return error.UnsupportedOp;
                }
            }
            const type_name = try wgslType(&module, actual_type, &names, arena);
            try w.print(") -> @location(0) {s} {{\n", .{type_name});
        }
    } else if (is_vertex and use_vertex_struct) {
        // VertexOutput already chosen above (multiple outputs, or a gl_PerVertex
        // block whose member 0 became the @builtin(position) field).
        try w.writeAll(") -> VertexOutput {\n");
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
                const interp: []const u8 = blk: {
                    if (hasDec(&decorations, ov, .flat) or isIntegerWgslType(type_name))
                        break :blk "@interpolate(flat) ";
                    if (hasDec(&decorations, ov, .no_perspective))
                        break :blk "@interpolate(linear) ";
                    break :blk "";
                };
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

    // Depth-output scan. Runs independently of the block above, which is guarded
    // on `output_var_id != null`: a depth-ONLY fragment (no @location output)
    // has output_var_id == null, so without this scan its stored depth was never
    // captured and the synthesized return hardcoded 0.0 (silent-wrong). Also
    // detects a READ-BACK depth (naga emits OpLoad of the FragDepth output for
    // `clamp(gl_FragDepth, ...)` read-modify-write shapes): the simple capture
    // path leaves those loads pointing at an undeclared name, so a read-back
    // depth needs a real local `var` instead. (#wgsl-cts)
    var depth_is_read = false;
    if (use_frag_depth_struct) {
        const dvid = depth_output_var_id.?;
        var sci: usize = entry_func_idx.? + 1;
        while (sci < module.instructions.len) : (sci += 1) {
            const si = module.instructions[sci];
            if (si.op == .FunctionEnd) break;
            if ((si.op == .Load or si.op == .AccessChain or si.op == .CopyObject) and si.words.len > 3 and si.words[3] == dvid) {
                depth_is_read = true;
            }
            if (si.op == .Store and si.words.len >= 3 and si.words[1] == dvid) {
                depth_return_value = names.get(si.words[2]);
                depth_return_id = si.words[2];
            }
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
            // On hostile SPIR-V the output variable id may not resolve to a real
            // definition (or the definition may lack a type operand); guard rather
            // than `.?`/index blindly, which was a null-deref crash.
            if (getDef(&module, ov)) |var_inst| {
                if (var_inst.words.len > 1) {
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
    // Depth output, simple case: its stores feed the FragmentOutput return, so
    // skip them in the body (ID-based; the legacy name-based skip missed every
    // depth var not literally named `gl_FragDepth`, e.g. all naga-produced
    // SPIR-V, leaving an undeclared `v3 = ...` store at exit 0). The read-back
    // case instead declares the depth var as a real local and lets every
    // store/load emit against it. (#wgsl-cts)
    if (use_frag_depth_struct) {
        const dvid = depth_output_var_id.?;
        if (!depth_is_read) {
            try mrt_skip_set.put(dvid, {});
        } else {
            var actual_type: u32 = getDef(&module, dvid).?.words[1];
            if (getDef(&module, actual_type)) |pi| {
                if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3];
            }
            const type_name = try wgslType(&module, actual_type, &names, arena);
            const var_name = names.get(dvid) orelse "depth_out";
            try w.print("    var {s}: {s};\n", .{ var_name, type_name });
            depth_return_value = arena.dupe(u8, var_name) catch var_name;
            depth_return_id = null;
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
    try emitBody(&module, &names, &decorations, entry_func_idx.?, w, alloc, arena, null, if (skip_output_var_decl) output_var_id else null, if (mrt_skip_set.count() > 0) &mrt_skip_set else null, &wrapped_uniform_arrays, &wrapped_uniform_members, &matrix_outputs, &atomic_vars, &atomic_fields, &nonuniform_gated, early_return_mode, subpass_fragcoord_name, null, null);

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
    // Per-@location-field return values, shared by the depth struct and the MRT
    // struct (field order == output_vars order == the emitted struct fields):
    // the local's name in the read/partial-write case, else the last whole-var
    // stored value, else the zero literal of the output's REAL type (a
    // hardcoded `vec4f()` mismatches a scalar field: naga type reject).
    // (#wgsl-cts)
    var frag_field_values = std.ArrayList(struct { val: []const u8 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    if (use_frag_depth_struct or use_frag_mrt_struct) {
        for (output_vars.items) |ovid| {
            const vn = names.get(ovid) orelse continue;
            var val: ?[]const u8 = null;
            if (mrt_is_read) {
                val = vn;
            } else {
                for (mrt_return_values.items) |rv| {
                    if (std.mem.eql(u8, rv.var_name, vn)) val = rv.value;
                }
            }
            if (val == null) {
                var zero_fallback: []const u8 = "vec4f()";
                if (getDef(&module, ovid)) |ovi| {
                    if (ovi.words.len > 1) {
                        var pt = ovi.words[1];
                        if (getDef(&module, pt)) |pi| {
                            if (pi.op == .TypePointer and pi.words.len > 3) pt = pi.words[3];
                        }
                        if (zeroLiteralOfType(&module, pt, &names, arena)) |z| zero_fallback = z;
                    }
                }
                val = zero_fallback;
            }
            try frag_field_values.append(arena, .{ .val = val.? });
        }
    }
    if (use_frag_depth_struct) {
        const depth_val = depth_return_value orelse "0.0";
        // Depth-only fragment: the struct has just the @builtin(frag_depth)
        // field (see its emission), so the constructor takes one argument.
        if (output_var_id == null) {
            try w.print("    return FragmentOutput({s});\n", .{depth_val});
        } else {
            // One argument per real @location field (in struct-field order),
            // then the depth. The old two-argument shape assumed a single
            // fabricated `color: vec4f` field. (#wgsl-cts)
            var d_parts = std.ArrayList(u8).initCapacity(arena, 128) catch return error.OutOfMemory;
            for (frag_field_values.items) |fv| {
                if (d_parts.items.len > 0) try d_parts.appendSlice(arena, ", ");
                try d_parts.appendSlice(arena, fv.val);
            }
            if (d_parts.items.len > 0) try d_parts.appendSlice(arena, ", ");
            try d_parts.appendSlice(arena, depth_val);
            try w.print("    return FragmentOutput({s});\n", .{d_parts.items});
        }
    } else if (use_frag_mrt_struct) {
        // Build FragmentOutput. Complex case (any output read/partially written):
        // the outputs are real local `var`s holding their final values, so return
        // them BY NAME (preserves `vo0.x += …` increments). Simple case: use the
        // captured whole-var store values.
        var mrt_parts = std.ArrayList(u8).initCapacity(arena, 256) catch return error.OutOfMemory;
        for (frag_field_values.items) |fv| {
            if (mrt_parts.items.len > 0) try mrt_parts.appendSlice(arena, ", ");
            try mrt_parts.appendSlice(arena, fv.val);
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
        const trimmed = std.mem.trimStart(u8, line, " ");
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

        // #wgsl-loop-merge-phi: assignments INSIDE a braced statement on the same
        // line -- the loop-exit idiom this backend emits is
        // `if (!(cond)) { vN = X; break; }`, which the line-initial pattern above
        // cannot see (the phi var then looked immutable, was demoted to `let`,
        // and the mid-line assignment became an invalid left-hand side).
        // Narrow scan: after every '{ ' or '; ' (statement starts inside a
        // line -- the loop-exit idiom packs several: `{ v39 = 0.0; v40 = v23;
        // break; }`) take an identifier followed by ' =' and register its base
        // (up to first '.'/'[').
        {
            var bp: usize = 0;
            while (true) {
                const b1 = if (std.mem.indexOfPos(u8, line, bp, "{ ")) |x| x else line.len;
                const b2 = if (std.mem.indexOfPos(u8, line, bp, "; ")) |x| x else line.len;
                if (b1 == line.len and b2 == line.len) break;
                const brace_idx = @min(b1, b2);
                bp = brace_idx + 2;
                const bs = brace_idx + 2;
                if (bs >= line.len) break;
                const c0 = line[bs];
                const word0 = (c0 >= 'a' and c0 <= 'z') or (c0 >= 'A' and c0 <= 'Z') or c0 == '_';
                if (!word0) continue;
                var be = bs;
                while (be < line.len) {
                    const c = line[be];
                    const word = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
                    if (!word) break;
                    be += 1;
                }
                if (be < line.len + 1 and be + 1 < line.len and line[be] == ' ' and line[be + 1] == '=' and
                    (be + 2 >= line.len or line[be + 2] != '='))
                {
                    // The identifier scan ends at `be` (identifiers cannot contain
                    // '.'/'['), so the base is simply line[bs..be]. An earlier
                    // version truncated at the first '.'/'[' to END OF LINE --
                    // which for `{ v39 = 0.0; v40 = v23; break; }` cut at the FLOAT
                    // LITERAL's dot and registered the base "v39 = 0": the var was
                    // demoted to `let` and the mid-line assignment rejected (hard
                    // naga-invalid for any float phi -- found in review).
                    const base = line[bs..be];
                    if (base.len > 0) {
                        const name_copy = try arena.dupe(u8, base);
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

/// #wgsl-region-mode: the NAME/ANALYSIS walk state emitBody accumulates in its
/// preamble and consults+mutates during emission. A region-mode (switch case
/// body) recursive call passes the PARENT's context: these are one-shot
/// function-wide mutations (inline-load renames, extract expressions, dead-set
/// skipping), NOT re-derivable tables -- re-running the preamble over the
/// already-mutated names minted expr-as-identifier names ('v17[v33]_ld') and
/// running with a fresh empty context emitted lets for loads the parent had
/// already inlined by name (both naga-invalid, both demonstrated on
/// graphicsfuzz_039/052/054 before this struct existed). Control-flow state
/// (loop_stack, merge_stack, indent) deliberately stays per-call: a region
/// balances its own constructs.
const SelPhi = struct { result_id: u32, value_id: u32, pred_label: u32 };

const WalkCtx = struct {
    use_count: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    def_op: std.AutoHashMapUnmanaged(u32, spirv.Op) = .empty,
    inline_loads: std.AutoHashMap(u32, void),
    declared_local_names: std.StringHashMap(void),
    store_targets: std.AutoHashMap(u32, void),
    sel_phis: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(SelPhi)) = .empty,
    extract_old_names: std.AutoHashMap(u32, []const u8),
    late_renamed_extracts: std.AutoHashMap(u32, void),
    dead_conditions: std.AutoHashMap(u32, void),
    dead_arith: std.AutoHashMap(u32, void),
    inline_exprs: std.AutoHashMap(u32, []const u8),
    hoisted_ids: std.AutoHashMap(u32, void),
    loop_hoists: std.AutoHashMap(usize, std.ArrayList(u32)),
    /// Extract results whose sole consumer is a CompositeConstruct (absorbed
    /// into a swizzle/ctor expression): emission skips their `let`. SHARED with
    /// regions -- the parent's prepass marked them dead and used their
    /// expression form; a fresh-empty set in a region would emit a `let` for an
    /// id whose name is an access expression (expr-as-identifier, naga-invalid).
    dead_extracts: std.AutoHashMap(u32, void),
    /// #wgsl-loop-merge-phi: merge-block phis the LoopMerge arm pre-declared
    /// above the loop. The other phi-declaration sites (the SelectionMerge
    /// pre-declaration, the .Phi arm's !already_declared path) must SKIP these
    /// -- a second declaration shadows the outer var, the exit assignments then
    /// mutate the shadow, and the post-loop read sees the zero init forever
    /// (valid WGSL, wrong values).
    declared_merge_phis: std.AutoHashMap(u32, void),
};

/// Replace pre-rename extract names inside CACHED expression strings -- the
/// values of `names` AND `ctx.inline_exprs`. Extracts get renamed at several
/// points AFTER the preamble (notably the deferred loop-header replay, which
/// expr-ifies header extracts at replay time with no `let` binding), but
/// expressions cached over the old name (access-chain exprs, single-use
/// arithmetic chains) keep referencing it: an identifier that is never bound
/// (naga "no definition in scope" -- demonstrated on graphicsfuzz_052, where
/// the cached `v17[v33]` referenced the replay-renamed `.y` extract while the
/// live build correctly had `v17[v32.y]`). Sweeping both maps against the
/// extract_old_names -> current-name table keeps every cached string
/// consistent with the live name state. Word-boundary guarded (v33 must not
/// match v334).
fn fixStaleExtractNames(names: *std.AutoHashMap(u32, []const u8), ctx: *WalkCtx, alloc: std.mem.Allocator, arena: std.mem.Allocator) !void {
    var fixup = std.ArrayList(struct { id: u32, new_val: []const u8, into_inline: bool }).initCapacity(alloc, 32) catch return;
    // NOTE: no per-item free -- ownership of new_val transfers to the map on
    // fetchPut (which frees the displaced old value); freeing here would
    // hand the maps dangling strings (invalid-UTF8 output, caught on gf_052).
    defer fixup.deinit(alloc);
    // names values
    {
        var it = names.iterator();
        while (it.next()) |entry| {
            var updated = entry.value_ptr.*;
            var owned = false; // intermediate concats are ours; the original belongs to the map (freed by fetchPut)
            var changed = false;
            var eon_it = ctx.extract_old_names.iterator();
            while (eon_it.next()) |eon| {
                const old_name = eon.value_ptr.*;
                if (old_name.len < 2) continue;
                const new_name = names.get(eon.key_ptr.*) orelse continue;
                if (std.mem.eql(u8, old_name, new_name)) continue;
                while (std.mem.indexOf(u8, updated, old_name)) |pos| {
                    const before_ok = pos == 0 or switch (updated[pos - 1]) {
                        ' ', '(', ',', '[', '+', '-', '*', '/', '=' => true,
                        else => false,
                    };
                    const after_idx = pos + old_name.len;
                    const after_ok = after_idx >= updated.len or switch (updated[after_idx]) {
                        ' ', ')', ',', ']', '+', '-', '*', '/', '=', '.', '\t' => true,
                        else => false,
                    };
                    if (before_ok and after_ok) {
                        const replacement = std.mem.concat(alloc, u8, &[_][]const u8{ updated[0..pos], new_name, updated[after_idx..] }) catch break;
                        if (owned) alloc.free(updated);
                        updated = replacement;
                        owned = true;
                        changed = true;
                    } else break;
                }
            }
            if (changed) fixup.append(alloc, .{ .id = entry.key_ptr.*, .new_val = updated, .into_inline = false }) catch {};
        }
    }
    // inline_exprs values
    {
        var it = ctx.inline_exprs.iterator();
        while (it.next()) |entry| {
            var updated = entry.value_ptr.*;
            // arena-backed map: arena-allocate replacements (the map values are
            // arena by convention); displacing a prior sweep value needs no free.
            var changed = false;
            var eon_it = ctx.extract_old_names.iterator();
            while (eon_it.next()) |eon| {
                const old_name = eon.value_ptr.*;
                if (old_name.len < 2) continue;
                const new_name = names.get(eon.key_ptr.*) orelse continue;
                if (std.mem.eql(u8, old_name, new_name)) continue;
                while (std.mem.indexOf(u8, updated, old_name)) |pos| {
                    const before_ok = pos == 0 or switch (updated[pos - 1]) {
                        ' ', '(', ',', '[', '+', '-', '*', '/', '=' => true,
                        else => false,
                    };
                    const after_idx = pos + old_name.len;
                    const after_ok = after_idx >= updated.len or switch (updated[after_idx]) {
                        ' ', ')', ',', ']', '+', '-', '*', '/', '=', '.', '\t' => true,
                        else => false,
                    };
                    if (before_ok and after_ok) {
                        const replacement = std.mem.concat(arena, u8, &[_][]const u8{ updated[0..pos], new_name, updated[after_idx..] }) catch break;

                        updated = replacement;

                        changed = true;
                    } else break;
                }
            }
            if (changed) fixup.append(alloc, .{ .id = entry.key_ptr.*, .new_val = updated, .into_inline = true }) catch {};
        }
    }
    for (fixup.items) |f| {
        if (f.into_inline) {
            _ = ctx.inline_exprs.fetchPut(f.id, f.new_val) catch {};
        } else {
            if (try names.fetchPut(f.id, f.new_val)) |old_entry| alloc.free(old_entry.value);
        }
    }
}

/// #wgsl-region-mode: an optional region-scoped entry into emitBody for code
/// the .Switch case-body walks cannot replay (a loop nested in a case). The
/// recursive call enters at `start_idx` (just past the region's opening Label),
/// SHARES the parent's WalkCtx (preamble passes are prepass-guarded and do not
/// re-run -- they are one-shot name mutations, see WalkCtx), stops at
/// `stop_label` (the switch merge: a top-level terminator branching there is
/// the implicit case end and emits nothing), and inherits the enclosing loop
/// context so `continue;` semantics survive. Null at every existing call site.
const RangeCtx = struct {
    start_idx: usize,
    stop_label: ?u32,
    indent: u32,
    loop_continue: ?u32 = null,
    loop_merge: ?u32 = null,
    depth: u32 = 0,
};

/// Depth cap for region-mode recursion (a case region containing a switch
/// whose case contains a region, ...). The MSL emitBlock x emitWhileLoopMSL
/// mutual recursion SIGSEGV'd on graphicsfuzz_022/082 before its guard; a
/// stack overflow on valid input is a mandate violation, so refuse loudly.
const max_region_depth: u32 = 256;

// ─────────────────────────────────────────────────────────────────────────
// #wgsl-uniformity-8k2: which implicit-Lod samples (and, since #685, which
// derivative instructions) sit in non-uniform flow
//
// WGSL gates the implicit-Lod sampling builtins (textureSample,
// textureSampleBias, textureSampleCompare and the proj-lowered forms of the
// three) on UNIFORM CONTROL FLOW: tint (Chrome/Dawn) and naga reject a module
// where the call runs after flow has diverged. The classic shape is a shader
// that early-returns inside a conditional and then samples: every text gate
// and the naga round-trip proxy were green while the wintty player rendered
// black, because only the consumer stack (the browser oracle) runs the real
// uniformity analysis (bead zioshade-8k2).
//
// The lowering mirrors what SPIRV-Cross does whenever an implicit-Lod form is
// not available in the target: pin the level to 0 (its MSL backend promotes a
// constant-zero gradient on sample_compare to `level(0)`). For the Bias
// operand there is no uniformity-safe WGSL form at all: WGSL has no
// textureQueryLod to fold a bias into an explicit level, and SPIRV-Cross's
// own MSL path likewise only DROPS a bias it cannot express (constant-zero
// bias on sample_compare is dropped outright there). So the bias is dropped
// and the level pinned to 0 rather than honest-erroring the whole shader,
// which would resurrect the black-player failure mode this class caused.
//
// WHICH samples get downgraded is decided by the analysis below, built to
// mirror what tint actually accepts. Every rule was probed on Chrome for
// Testing through tools/wgsl_browser_check.mjs with hand-written WGSL
// overrides (probe names cited at each rule):
//   * flow(B) = OR over the contributions of B's incoming edges (a block is
//     uniform when some edge delivers the FULL invocation set, either
//     directly or by reconverging every path that diverged):
//       - P ends in OpBranch: flow(P)
//       - P ends in OpBranchConditional/OpSwitch on a UNIFORM value: flow(P)
//       - P ends in OpBranchConditional/OpSwitch on a NON-uniform value:
//         the region's entry flow if B postdominates P, else non-uniform.
//         Postdominance is what keeps a MERGE where every path reconverges
//         uniform (probe p10: an `if (nonuniform) { ... }` whose arms
//         complete keeps the following sample implicit), while a merge
//         reached by a SUBSET is non-uniform (probe p03: early return in
//         one arm; p13: conditional break; p09: varying-bound loop body).
//       - loop-prelude blocks (the header chain up to the trip-count
//         conditional, plus the continue block) execute once PER ITERATION,
//         so their flow is the loop's entry flow gated by the uniformity of
//         the trip-count conditions (probe p07/p09).
//   * OpKill is NOT an exit for postdominance (probe p20: a discard does not
//     poison the following flow; the invocation keeps executing statements).
//   * value seeds: constants, and loads through pointers rooted at a variable
//     THIS BACKEND EMITS AS `var<uniform>` OR READ-ONLY `var<storage>`, whose
//     dynamic indices are uniform (probe p04: a member read is uniform; p22: a
//     NON-uniform index into a uniform array is not). The predicate is the
//     emitted ADDRESS SPACE, not the SPIR-V storage class: glslang targeting
//     Vulkan 1.0 puts an SSBO in StorageClass Uniform (BufferBlock on the
//     struct) and from Vulkan 1.1 in StorageClass StorageBuffer, and WGSL
//     calls a read_write storage read NON-uniform and a read-only one uniform.
//     See readIsUniformStorage.
//   * values propagate through pure ops; a phi is uniform only when every
//     incoming value is uniform AND every incoming edge left its block on a
//     uniform branch (probe p17: a phi of constants across a non-uniform if
//     is non-uniform; p24: across a uniform if it stays uniform).
//   * a store into a FUNCTION-scope variable reaches only the loads its block
//     can actually flow to (#684): the store rule is FLOW-SENSITIVE within
//     one function, on the successor graph with loop back edges included, so
//     a store later in a loop body still poisons an earlier load on the next
//     iteration while a store AFTER a load it can no longer reach does not
//     poison it. tint's local-variable uniformity is flow-sensitive the same
//     way. Module-scope Private/Output roots keep the flow-insensitive rule
//     (see the imprecision list below for why).
//   * helper functions inherit the flow of their CALL SITES (probe p11/p12)
//     and a parameter is a uniform value iff every call site passes a
//     uniform argument (probe p23a/p23b). Both are interprocedural and
//     resolved by the same downward fixpoint.
//   * a function-call RESULT is uniform iff every OpReturnValue of the callee
//     returns a uniform value from a block with uniform flow (#684; probed:
//     a uniform value returned from a diverged arm is NON-uniform, the same
//     selection rule as a phi edge, while a return after a reconverged if or
//     selected by a uniform condition stays uniform). This is a third
//     interprocedural component of the same downward fixpoint.
// The analysis is deliberately conservative where it cannot model tint
// exactly (pointer PARAMETERS are never uniform VALUES; loads through them
// are judged from the call sites instead).
//
// WHAT THIS DOES NOT COVER. An earlier version of this comment claimed the
// analysis "never claims uniformity the probes showed tint rejecting, so the
// emitted module can only be MORE accepted, never less". That was FALSE and is
// retracted. It was wrong on its own terms once (the value seed keyed off the
// SPIR-V storage class, so a Vulkan-1.0 SSBO read counted as uniform, the
// implicit sample was kept, and tint rejected the module; fixed above by
// readIsUniformStorage), and the claim is not something the analysis can
// promise in general: it is a heuristic mirror of tint's rules, not tint.
// Known imprecisions in the SAFE direction, all silent MIP CHANGES rather
// than rejects, are left standing on purpose:
//   * the #684 store-reachability filter applies ONLY to stores in the SAME
//     function as the load, only when that function is not on a call-graph
//     cycle, and only when the variable itself is FUNCTION-scope: the filter
//     argues about ONE invocation, and only a Function-scope variable's
//     contents live and die with one. A module-scope Private or Output root
//     persists across SEQUENTIAL calls of the same function (a store by an
//     earlier call can feed a load of a later one from an unreachable block;
//     the #684 review repro), so for those, for stores made in a DIFFERENT
//     function, and for cyclic functions, every store counts unconditionally.
//     Stores a callee makes through a pointer parameter are likewise judged
//     per PARAMETER (every store through it uniform), not per reaching store
//     site within the callee.
//   * the #684 return rule consults the callee's flow, whose entry is the
//     AND of its call sites: a helper with ONE non-uniform call site has
//     every block poisoned, so its result is called non-uniform even at its
//     uniform call sites where tint would keep it (and where a same-shaped
//     phi of the returned values would stay uniform). Functions on a
//     call-graph cycle keep the pre-#684 verdict outright: their result is
//     never called uniform.
//
// The DERIVATIVE half of the same WGSL rule was once a knowingly-open gap in
// the UNSAFE direction here and is IN SCOPE since #685
// (#wgsl-uniformity-8k2-derivatives): WGSL gates dpdx/dpdxCoarse/dpdxFine and
// the dpdy/fwidth families on uniform control flow exactly as it gates
// textureSample, so this prepass ALSO marks the nine derivative opcodes that
// sit in non-uniform flow, on the same flow verdict the samples use. But
// where a marked sample is LOWERED (the explicit-Level pin), a marked
// derivative is REFUSED at emission: WGSL has no explicit-derivative form to
// pin anything to, so there is no downgrade path and the honest error naming
// the hoist workaround is the only correct move (see
// recordUnsupportedNonuniformDerivative and the derivative arms in emitBody).
// Both imprecisions listed above still apply to that marking in the SAFE
// direction: a wrongly-marked derivative refuses a shader tint would have
// accepted, never the reverse.
// ─────────────────────────────────────────────────────────────────────────

/// Terminator classification for one CFG block of the uniformity walk.
const UniTerm = union(enum) {
    branch: u32,
    cond: struct { cond: u32, t: u32, f: u32 },
    swit: struct { sel: u32, targets: []const u32 },
    ret,
    kill,
    unreach,
};

const UniBlock = struct {
    label: u32,
    term: UniTerm,
    /// successor block indices (resolved once the whole function is parsed)
    succs: []const usize,
    /// predecessor block indices (resolved once the whole function is parsed)
    preds: []const usize = &.{},
    flow: bool = true,
};

/// One OpFunctionCall site: the callee, the block the call sits in, and the
/// argument ids (a parameter is uniform iff every site passes a uniform arg).
const UniCall = struct { callee: u32, block: usize, args: []const u32 };

/// One implicit-Lod sample instruction: its result id (the key the emitter
/// consults) and the block it sits in. The same record shape carries the
/// DERIVATIVE instructions (see UniFunc.derivatives): result id plus block is
/// all either consumer needs.
const UniSample = struct { result: u32, block: usize };

/// One OpStore into a function/output-scope variable: what was stored, and
/// the block the store sits in (glslang lowers locals and loop counters to
/// variables, not phis, so uniform values flow through stores).
const UniStore = struct { root: u32, val: u32, func: usize, block: usize };

/// One OpStore THROUGH a pointer parameter (glslang's ABI passes every GLSL
/// parameter as ptr<function, T>, so helper reads of a parameter are loads
/// through the pointer the caller synthesized around its argument local).
const UniParamStore = struct { func: usize, param: usize, val: u32, block: usize };

/// One call argument that is a pointer to a variable: parameter position `pos`
/// of `callee` receives (a chain rooted at) `root`. Ties the callee's loads
/// through that parameter to the caller's stores into the variable. The call
/// site (`caller`, `block`) is what the #684 reachability filter consults: a
/// callee store through this pointer only matters to a load the CALL can feed.
const UniArgVar = struct { callee: u32, pos: usize, root: u32, caller: usize, block: usize };

/// One OpReturnValue: the value returned and the block it returns from. The
/// block is load-bearing (#684): tint judges a return from a DIVERGED arm
/// non-uniform even when the returned value is uniform (probed; the same
/// selection rule as a phi edge), so the return rule needs WHERE, not just
/// WHAT.
const UniReturn = struct { val: u32, block: usize };

/// WHERE a load sits (function index + block index). The #684 store rule
/// counts only stores whose block can REACH this point; null means "location
/// unknown" and disables the filter (every store counts, the conservative
/// pre-#684 verdict).
const UniLoc = struct { func: usize, block: usize };

/// One structured loop: the header block (where OpLoopMerge sits), the
/// continue block, the prelude blocks (header chain up to the conditional
/// that governs the trip count, plus the continue block itself) and the
/// conditions governing that trip count. Statements in the prelude execute
/// once PER ITERATION, so their flow is gated by the trip count's
/// uniformity, not just by the loop entry's flow.
const UniLoop = struct {
    header: usize,
    continue_block: ?usize,
    prelude: []const usize,
    governing: []const u32,
};

const UniFunc = struct {
    id: u32,
    params: []const u32,
    blocks: []UniBlock,
    entry_block: usize,
    calls: []const UniCall,
    samples: []const UniSample,
    returns: []const UniReturn,
    /// the derivative instructions of this function (#685): unlike samples
    /// they have no uniformity-safe lowered form, so the emitter REFUSES them
    derivatives: []const UniSample,
    is_entry_point: bool,
    /// fixpoint variables: only ever move DOWN from true
    entry_flow: bool = true,
    param_uniform: []bool,
    /// (#684) fixpoint variable: this function's RESULT is a uniform value
    returns_uniform: bool = true,
};

const UniformityAnalysis = struct {
    module: *const ParsedModule,
    /// the module's decorations, needed to tell a real UBO and a READ-ONLY
    /// storage buffer (both uniform reads) from a read_write one (not)
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    arena: std.mem.Allocator,
    funcs: []UniFunc,
    func_by_id: std.AutoHashMap(u32, usize),
    label_to_block: []std.AutoHashMap(u32, usize),
    /// result id -> owning function index (phi/parameter classification)
    owner_func: std.AutoHashMap(u32, usize),
    /// result id -> block index within its owning function. The #684 store
    /// rule needs WHERE a load sits, not just which function owns it.
    block_of: std.AutoHashMap(u32, usize),
    /// parameter result id -> parameter index in its function
    param_index: std.AutoHashMap(u32, usize),
    /// ids currently believed to hold UNIFORM VALUES (downward fixpoint)
    values: std.AutoHashMap(u32, void),
    /// every OpStore into a function/output-scope variable, as ONE FLAT LIST
    /// (an earlier version of this comment claimed they were grouped by root
    /// variable; they never were). varStoresUniform LINEARLY SCANS the whole
    /// list on every call and every fixpoint round, so a query costs
    /// O(all stores), not O(stores into this root). Grouping by root is the
    /// obvious win if this ever shows up in a profile; nothing measured has.
    stores: std.ArrayListUnmanaged(UniStore) = .empty,
    /// all OpStores through a pointer parameter (flat, scanned like `stores`)
    param_stores: std.ArrayListUnmanaged(UniParamStore) = .empty,
    /// call arguments that are pointers to variables (flat, scanned likewise)
    arg_vars: std.ArrayListUnmanaged(UniArgVar) = .empty,
    /// (function, param index) whose argument pointer could not be resolved
    /// to a variable (forwarded pointer params, opaque aliasing)
    opaque_params: std.AutoHashMap(u64, void),
    /// (function, block) -> loop header block, for every prelude block
    prelude_of: std.AutoHashMap(u64, u64),
    /// function index -> its loops
    loops_of: []std.ArrayListUnmanaged(UniLoop),
    /// raw OpLoopMerge records (header block LABEL -> merge/continue labels),
    /// resolved into UniLoop prelude/governing data once the function is
    /// parsed; label ids are globally unique, block indices are not
    loop_merges: std.AutoHashMap(u32, UniLoopMerge),
    /// per-function transitive block-reachability rows, computed LAZILY on
    /// first query (#684): rows[from][to] says some CFG path leads from block
    /// `from` to block `to`. Built from the RAW successor graph (loop back
    /// edges included), because the store rule is a MAY-WRITE filter: a store
    /// later in a loop body still feeds a load earlier in the same loop on the
    /// next iteration. The diagonal is true: within one block the store/load
    /// order is not modelled, so a store in the load's own block counts.
    reach_rows: []?[]const []const bool = &.{},
    /// functions that can reach THEMSELVES through at least one call edge
    /// (self-recursion or a cycle, #684). Both #684 rules need one invocation
    /// to be the only relevant one: same-function store reachability and
    /// return-value uniformity are only sound for functions that cannot be on
    /// the stack twice, so cyclic functions keep the pre-#684 conservative
    /// verdicts (count every store, never a uniform result).
    recursive_funcs: []const bool = &.{},
    /// scratch (reused, arena-backed): postdominance DFS
    visited: std.AutoHashMap(usize, void),
    dfs_stack: std.ArrayListUnmanaged(usize) = .empty,

    /// Recursion cap shared by EVERY recursive helper in this struct: the
    /// pointer/index walks (pointerRoot, pointerParamOf, chainIndicesUniform)
    /// and the regionEntry -> loopEntryFlow -> edgeContribution cycle.
    ///
    /// The flow cycle is NOT self-terminating on arbitrary SPIR-V: a loop
    /// header with a second back edge from one of its own PRELUDE blocks (a
    /// prelude block whose non-uniform conditional targets the header on both
    /// arms) sends regionEntry(prelude) -> loopEntryFlow(header) ->
    /// edgeContribution(prelude, header) -> regionEntry(prelude) round forever
    /// and blows the stack. spirv-val rejects that module, but the CTS and
    /// external-ingestion paths feed non-glslang SPIR-V and the other three
    /// backends honest-error on it, so a SIGSEGV here is a mandate violation.
    /// Hitting the cap yields NON-uniform / no-root, the conservative
    /// direction: the sample is downgraded, never wrongly kept implicit.
    const max_flow_depth: u32 = 64;

    /// Walk a pointer chain to its root OpVariable id (null when the chain
    /// bottoms out at a parameter or an unknown op).
    fn pointerRoot(a: *UniformityAnalysis, ptr_id: u32, depth: u32) ?u32 {
        if (depth > max_flow_depth) return null;
        const inst = common.getDef(a.module, ptr_id) orelse return null;
        return switch (inst.op) {
            .Variable => ptr_id,
            // getDef only guarantees words.len >= 3 (the instruction defines an
            // id); a TRUNCATED chain op would index past the end. Non-glslang
            // SPIR-V reaches this walk, so answer "unknown root" rather than
            // panic.
            .AccessChain, .CopyObject => if (inst.words.len > 3) a.pointerRoot(inst.words[3], depth + 1) else null,
            else => null,
        };
    }

    /// If `ptr_id` bottoms out at one of `params` (this function's pointer
    /// parameters), return its index; null otherwise. glslang passes every
    /// GLSL parameter this way, so loads/stores through parameters are the
    /// COMMON shape for helper functions, not an exotic one.
    fn pointerParamOf(a: *UniformityAnalysis, params: []const u32, ptr_id: u32, depth: u32) ?usize {
        if (depth > max_flow_depth) return null;
        const inst = common.getDef(a.module, ptr_id) orelse return null;
        switch (inst.op) {
            // truncated chain op: unknown parameter, not an out-of-bounds index
            .AccessChain, .CopyObject => return if (inst.words.len > 3) a.pointerParamOf(params, inst.words[3], depth + 1) else null,
            .FunctionParameter => {
                for (params, 0..) |pid, pi| {
                    if (pid == ptr_id) return pi;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Parse every function into blocks, call sites, stores and loops.
    fn parse(a: *UniformityAnalysis) !void {
        var funcs = std.ArrayListUnmanaged(UniFunc).empty;
        var label_maps = std.ArrayListUnmanaged(std.AutoHashMap(u32, usize)).empty;
        var loop_lists = std.ArrayListUnmanaged(std.ArrayListUnmanaged(UniLoop)).empty;
        const m = a.module;
        var i: usize = 0;
        while (i < m.instructions.len) : (i += 1) {
            if (m.instructions[i].op != .Function) continue;
            const func_id = if (m.instructions[i].words.len > 2) m.instructions[i].words[2] else 0;
            const my_index = funcs.items.len;
            var params = std.ArrayListUnmanaged(u32).empty;
            var blocks = std.ArrayListUnmanaged(UniBlock).empty;
            var terms = std.ArrayListUnmanaged(UniTerm).empty;
            var calls = std.ArrayListUnmanaged(UniCall).empty;
            var samples = std.ArrayListUnmanaged(UniSample).empty;
            var returns = std.ArrayListUnmanaged(UniReturn).empty;
            var derivs = std.ArrayListUnmanaged(UniSample).empty;
            var loops = std.ArrayListUnmanaged(UniLoop).empty;
            var cur_block: usize = 0;
            var j: usize = i + 1;
            while (j < m.instructions.len and m.instructions[j].op != .FunctionEnd) : (j += 1) {
                const inst = m.instructions[j];
                // Attribute every RESULT id in this function to it, so phi and
                // parameter classification can find the context. The id must
                // come from the same predicate the module parser used to build
                // id_defs: words[2] is a result only where the opcode HAS one
                // (for OpStore it is the stored value, for OpBranchConditional
                // the true label, for OpSelectionMerge the control-mask
                // LITERAL), and putting those in would attribute an unrelated
                // id to this function -- .Phi would then look up the wrong
                // block and call a uniform value non-uniform.
                if (common.resultIdFromOp(inst.op, inst.words)) |rid| {
                    if (inst.op != .Label) {
                        try a.owner_func.put(rid, my_index);
                        // #684: the store rule needs the load's block too.
                        // Same result-id predicate as owner_func, same guard.
                        try a.block_of.put(rid, cur_block);
                    }
                }
                switch (inst.op) {
                    .FunctionParameter => {
                        if (inst.words.len > 2) try params.append(a.arena, inst.words[2]);
                    },
                    .Label => {
                        if (inst.words.len > 1) {
                            try blocks.append(a.arena, .{ .label = inst.words[1], .term = .unreach, .succs = &.{} });
                            try terms.append(a.arena, .unreach);
                            cur_block = blocks.items.len - 1;
                        }
                    },
                    .Branch => {
                        if (inst.words.len > 1) terms.items[cur_block] = .{ .branch = inst.words[1] };
                    },
                    .BranchConditional => {
                        if (inst.words.len > 3) terms.items[cur_block] = .{ .cond = .{ .cond = inst.words[1], .t = inst.words[2], .f = inst.words[3] } };
                    },
                    .Switch => {
                        var targets = std.ArrayListUnmanaged(u32).empty;
                        if (inst.words.len > 2) {
                            try targets.append(a.arena, inst.words[2]); // default target
                            var wi: usize = 3;
                            while (wi + 1 < inst.words.len) : (wi += 2) {
                                try targets.append(a.arena, inst.words[wi + 1]);
                            }
                        }
                        terms.items[cur_block] = .{ .swit = .{ .sel = if (inst.words.len > 1) inst.words[1] else 0, .targets = targets.items } };
                    },
                    .Return => terms.items[cur_block] = .ret,
                    .ReturnValue => {
                        terms.items[cur_block] = .ret;
                        // #684: WHAT comes back and FROM WHERE (a return from
                        // a diverged arm is a non-uniform result for tint even
                        // when the value is uniform; words[1] is the value,
                        // OpReturnValue has no result id of its own).
                        if (inst.words.len > 1) try returns.append(a.arena, .{ .val = inst.words[1], .block = cur_block });
                    },
                    .Kill => terms.items[cur_block] = .kill,
                    .Unreachable => terms.items[cur_block] = .unreach,
                    .LoopMerge => {
                        // merge = words[1], continue = words[2]; the prelude
                        // and governing conditions are resolved after the
                        // whole function is parsed (targets are forward).
                        try loops.append(a.arena, .{
                            .header = cur_block,
                            .continue_block = null,
                            .prelude = &.{},
                            .governing = &.{},
                        });
                        try a.loop_merges.put(blocks.items[cur_block].label, .{
                            .merge = if (inst.words.len > 1) inst.words[1] else 0,
                            .cont = if (inst.words.len > 2) inst.words[2] else 0,
                        });
                    },
                    .FunctionCall => {
                        if (inst.words.len > 3) {
                            var args = std.ArrayListUnmanaged(u32).empty;
                            for (inst.words[4..]) |arg| try args.append(a.arena, arg);
                            try calls.append(a.arena, .{ .callee = inst.words[3], .block = cur_block, .args = args.items });
                            // Tie pointer arguments to the variables they
                            // alias so the callee's loads through them can be
                            // judged from the caller's stores. An argument
                            // that is neither a variable chain nor one of this
                            // function's own parameters makes the callee's
                            // parameter opaque (conservative non-uniform).
                            for (args.items, 0..) |arg, pos| {
                                if (a.pointerRoot(arg, 0)) |root| {
                                    try a.arg_vars.append(a.arena, .{ .callee = inst.words[3], .pos = pos, .root = root, .caller = my_index, .block = cur_block });
                                } else if (a.pointerParamOf(params.items, arg, 0)) |_| {
                                    const callee_idx = blk: {
                                        const fid = inst.words[3];
                                        for (funcs.items, 0..) |ff, ffi| {
                                            if (ff.id == fid) break :blk ffi;
                                        }
                                        break :blk null;
                                    };
                                    if (callee_idx) |ci| try a.opaque_params.put(packParamKey(ci, pos), {});
                                }
                            }
                        }
                    },
                    .Store => {
                        if (inst.words.len > 2) {
                            if (a.pointerRoot(inst.words[1], 0)) |root| {
                                try a.stores.append(a.arena, .{ .root = root, .val = inst.words[2], .func = my_index, .block = cur_block });
                            } else if (a.pointerParamOf(params.items, inst.words[1], 0)) |pi| {
                                try a.param_stores.append(a.arena, .{ .func = my_index, .param = pi, .val = inst.words[2], .block = cur_block });
                            }
                        }
                    },
                    .ImageSampleImplicitLod, .ImageSampleDrefImplicitLod, .ImageSampleProjImplicitLod, .ImageSampleProjDrefImplicitLod => {
                        if (inst.words.len > 2) {
                            try samples.append(a.arena, .{ .result = inst.words[2], .block = cur_block });
                        }
                    },
                    // #685: the derivative builtins are gated on uniform
                    // control flow by the same WGSL rule, and they have no
                    // lowered form, so a non-uniform one is REFUSED at
                    // emission rather than downgraded. Collected here so the
                    // fixpoint's flow verdict (including the interprocedural
                    // call-site rule) can mark them exactly as it marks
                    // samples. The list is every derivative opcode there is
                    // (spec 207-215: plain/Fine/Coarse dpdx, dpdy, fwidth;
                    // all named in spirv.Op, so no raw numeric gap applies).
                    .DPdx, .DPdy, .Fwidth, .DPdxFine, .DPdyFine, .FwidthFine, .DPdxCoarse, .DPdyCoarse, .FwidthCoarse => {
                        if (inst.words.len > 2) {
                            try derivs.append(a.arena, .{ .result = inst.words[2], .block = cur_block });
                        }
                    },
                    else => {
                        // OpTerminateInvocation is SPIR-V 1.6's OpKill: a
                        // DISCARD-LIKE block terminator. spirv.Op does not name
                        // it, so it cannot have a `.TerminateInvocation` arm and
                        // lands here; without this line the block would keep its
                        // `.unreach` default and `postdominates` would count it
                        // as an EXIT, which is the exact OPPOSITE of the
                        // deliberate OpKill rule documented there (a discard is a
                        // dead end, not a path that bypasses the merge). It gets
                        // the OpKill classification for the same reason: a
                        // terminated invocation contributes no path to a return.
                        // Nothing can observe this yet -- the WGSL emitter
                        // honest-errors on opcode 4416 ("unsupported op ... in
                        // main emit path"), so no module carrying one reaches
                        // emission -- but the classification is then already
                        // right the day the emitter grows a `discard;` arm.
                        if (isTerminateInvocation(inst.op)) terms.items[cur_block] = .kill;
                    },
                }
            }
            // resolve label ids -> block indices (targets may be defined later)
            var lmap = std.AutoHashMap(u32, usize).init(a.arena);
            for (blocks.items, 0..) |blk, bi| try lmap.put(blk.label, bi);
            var resolved = std.ArrayListUnmanaged(UniBlock).empty;
            for (blocks.items, 0..) |blk, bi| {
                const term = terms.items[bi];
                var succs = std.ArrayListUnmanaged(usize).empty;
                switch (term) {
                    .branch => |t| if (lmap.get(t)) |ti| try succs.append(a.arena, ti),
                    .cond => |c| {
                        if (lmap.get(c.t)) |ti| try succs.append(a.arena, ti);
                        if (lmap.get(c.f)) |ti| try succs.append(a.arena, ti);
                    },
                    .swit => |s| for (s.targets) |t| {
                        if (lmap.get(t)) |ti| try succs.append(a.arena, ti);
                    },
                    // terminators that leave the function: no successor block
                    .ret, .kill, .unreach => {},
                }
                try resolved.append(a.arena, .{ .label = blk.label, .term = term, .succs = succs.items });
            }
            // predecessor lists, once (the flow pass iterates them per block)
            {
                var preds = try a.arena.alloc(std.ArrayListUnmanaged(usize), resolved.items.len);
                for (preds) |*pl| pl.* = .empty;
                for (resolved.items, 0..) |blk, bi| {
                    for (blk.succs) |s| {
                        if (s < preds.len) try preds[s].append(a.arena, bi);
                    }
                }
                for (resolved.items, 0..) |*blk, bi| blk.preds = preds[bi].items;
            }
            // resolve each loop's prelude chain and governing conditions
            for (loops.items) |*lp| {
                var prelude = std.ArrayListUnmanaged(usize).empty;
                var governing = std.ArrayListUnmanaged(u32).empty;
                var cb: usize = lp.header;
                var guard: u32 = 0;
                while (guard < blocks.items.len + 1) : (guard += 1) {
                    try prelude.append(a.arena, cb);
                    switch (resolved.items[cb].term) {
                        .cond => |c| {
                            try governing.append(a.arena, c.cond);
                            break;
                        },
                        .swit => |s| {
                            try governing.append(a.arena, s.sel);
                            break;
                        },
                        .branch => |t| {
                            const nxt = lmap.get(t) orelse break;
                            if (nxt == cb) break; // degenerate self chain
                            cb = nxt;
                        },
                        // the header chain left the function before reaching any
                        // conditional: there is no trip-count condition to record
                        .ret, .kill, .unreach => break,
                    }
                }
                var continue_block: ?usize = null;
                if (a.loop_merges.getPtr(resolved.items[lp.header].label)) |lm| {
                    if (lmap.get(lm.cont)) |ci| {
                        continue_block = ci;
                        try prelude.append(a.arena, ci);
                        switch (resolved.items[ci].term) {
                            .cond => |c| try governing.append(a.arena, c.cond),
                            .swit => |s| try governing.append(a.arena, s.sel),
                            // an unconditional continue governs nothing
                            .branch, .ret, .kill, .unreach => {},
                        }
                    }
                }
                lp.continue_block = continue_block;
                lp.prelude = prelude.items;
                lp.governing = governing.items;
            }
            const param_uni = try a.arena.alloc(bool, params.items.len);
            @memset(param_uni, true);
            try funcs.append(a.arena, .{
                .id = func_id,
                .params = params.items,
                .blocks = resolved.items,
                .entry_block = 0,
                .calls = calls.items,
                .samples = samples.items,
                .returns = returns.items,
                .derivatives = derivs.items,
                .is_entry_point = func_id == a.module.entry_point_id,
                .entry_flow = true,
                .param_uniform = param_uni,
                .returns_uniform = true,
            });
            try label_maps.append(a.arena, lmap);
            try loop_lists.append(a.arena, loops);
            i = j;
        }
        a.funcs = funcs.items;
        a.label_to_block = label_maps.items;
        a.loops_of = loop_lists.items;
        const rows = try a.arena.alloc(?[]const []const bool, funcs.items.len);
        @memset(rows, null);
        a.reach_rows = rows;
        for (a.funcs, 0..) |*uf, fi| {
            try a.func_by_id.put(uf.id, fi);
            for (uf.params, 0..) |pid, pi| {
                try a.owner_func.put(pid, fi);
                try a.param_index.put(pid, pi);
            }
            for (a.loops_of[fi].items) |lp| {
                for (lp.prelude) |pb| try a.prelude_of.put(packFlowKey(fi, pb), @intCast(lp.header));
            }
        }
        // AFTER func_by_id exists: the cycle walk resolves callee ids.
        try a.computeRecursive();
    }

    /// Mark every function that can reach ITSELF through at least one call
    /// edge (self-recursion or a mutual cycle). Both #684 rules model ONE
    /// invocation of a function: a store reaches a load along a CFG path of
    /// the SAME invocation, and a return value is what ONE invocation returns.
    /// Recursion breaks both in the unsafe direction -- a store executed by an
    /// OUTER invocation can feed a load of an INNER one with no same-frame CFG
    /// path between them -- so functions on a cycle keep the pre-#684 rules.
    /// glslang cannot emit recursion (GLSL forbids it); this guard exists for
    /// hand-authored or external SPIR-V. O(F * (F + E)) on the call graph.
    fn computeRecursive(a: *UniformityAnalysis) !void {
        const rec = try a.arena.alloc(bool, a.funcs.len);
        @memset(rec, false);
        for (0..a.funcs.len) |fi| {
            a.visited.clearRetainingCapacity();
            a.dfs_stack.clearRetainingCapacity();
            for (a.funcs[fi].calls) |call| {
                if (a.func_by_id.get(call.callee)) |ci| try a.dfs_stack.append(a.arena, ci);
            }
            while (a.dfs_stack.items.len > 0) {
                const ci = a.dfs_stack.items[a.dfs_stack.items.len - 1];
                a.dfs_stack.items.len -= 1;
                if (ci == fi) {
                    rec[fi] = true;
                    break;
                }
                if (a.visited.contains(ci)) continue;
                try a.visited.put(ci, {});
                for (a.funcs[ci].calls) |call| {
                    if (a.func_by_id.get(call.callee)) |cj| try a.dfs_stack.append(a.arena, cj);
                }
            }
        }
        a.recursive_funcs = rec;
    }

    /// The transitive block-reachability rows of function `fi`, built on
    /// first use (most functions never need them: only a load of a
    /// Function/Output/Private-scope variable consults the store filter).
    /// Null only on allocation failure; callers treat that as "reachability
    /// unknown", i.e. every store counts (the conservative direction).
    fn reachRow(a: *UniformityAnalysis, fi: usize) ?[]const []const bool {
        if (fi >= a.funcs.len) return null;
        if (a.reach_rows[fi]) |rows| return rows;
        const uf = &a.funcs[fi];
        const rows = a.arena.alloc([]bool, uf.blocks.len) catch return null;
        for (rows) |*r| {
            const row = a.arena.alloc(bool, uf.blocks.len) catch return null;
            @memset(row, false);
            r.* = row;
        }
        for (0..uf.blocks.len) |from| {
            // a block trivially reaches itself: intra-block store/load order
            // is not modelled, so a store in the load's own block counts.
            rows[from][from] = true;
            a.visited.clearRetainingCapacity();
            a.dfs_stack.clearRetainingCapacity();
            a.visited.put(from, {}) catch return null;
            for (uf.blocks[from].succs) |s| a.dfs_stack.append(a.arena, s) catch return null;
            while (a.dfs_stack.items.len > 0) {
                const bi = a.dfs_stack.items[a.dfs_stack.items.len - 1];
                a.dfs_stack.items.len -= 1;
                if (a.visited.contains(bi)) continue;
                a.visited.put(bi, {}) catch return null;
                rows[from][bi] = true;
                for (uf.blocks[bi].succs) |s| a.dfs_stack.append(a.arena, s) catch return null;
            }
        }
        a.reach_rows[fi] = rows;
        return rows;
    }

    /// Can block `from` reach block `to` in function `fi`'s successor graph?
    /// Answers TRUE whenever the answer is unavailable (no such function,
    /// allocation failure, out-of-range block): this is a MAY-WRITE filter
    /// for the store rule, so "cannot prove irrelevance" must mean "counts",
    /// never the other way.
    fn blockReaches(a: *UniformityAnalysis, fi: usize, from: usize, to: usize) bool {
        const rows = a.reachRow(fi) orelse return true;
        if (from >= rows.len or to >= rows.len) return true;
        return rows[from][to];
    }

    /// Does block `target` postdominate block `from`: does every path from
    /// `from` to a function exit pass through `target`? Computed as a DFS
    /// from `from` that AVOIDS `target`; if it still reaches an exit block
    /// (OpReturn/OpReturnValue/OpUnreachable) then a path bypasses `target`.
    /// OpKill is deliberately NOT an exit (probe p20: a discard does not
    /// poison the following flow, so kill paths are dead ends, not exits).
    ///
    /// An allocation failure in the DFS scratch answers `false` (no
    /// postdominance) rather than propagating: the caller chain is all `bool`.
    /// That is the CONSERVATIVE direction -- it can only cost extra
    /// downgrades, never an implicit sample tint would reject -- but it does
    /// mean a shader compiled under memory pressure can pick a different mip
    /// than the same shader compiled normally.
    fn postdominates(a: *UniformityAnalysis, fi: usize, from: usize, target: usize) bool {
        const uf = &a.funcs[fi];
        a.visited.clearRetainingCapacity();
        a.dfs_stack.clearRetainingCapacity();
        for (uf.blocks[from].succs) |s| a.dfs_stack.append(a.arena, s) catch return false;
        while (a.dfs_stack.items.len > 0) {
            const bi = a.dfs_stack.items[a.dfs_stack.items.len - 1];
            a.dfs_stack.items.len -= 1;
            if (bi == target) continue;
            if (a.visited.contains(bi)) continue;
            a.visited.put(bi, {}) catch return false;
            switch (uf.blocks[bi].term) {
                .ret, .unreach => return false, // an exit path avoids `target`
                // .kill is deliberately NOT an exit (see the doc comment); the
                // rest have successors the DFS keeps walking.
                .branch, .cond, .swit, .kill => {},
            }
            for (uf.blocks[bi].succs) |s| a.dfs_stack.append(a.arena, s) catch return false;
        }
        return true;
    }

    /// The loop whose prelude contains `bi`, or null.
    fn preludeLoop(a: *UniformityAnalysis, fi: usize, bi: usize) ?*UniLoop {
        const header = a.prelude_of.get(packFlowKey(fi, bi)) orelse return null;
        for (a.loops_of[fi].items) |*lp| {
            if (lp.header == header) return lp;
        }
        return null;
    }

    /// The flow a block contributes when reconvergence at its target makes
    /// the branch's divergence irrelevant: the loop's ENTRY flow for prelude
    /// blocks, the block's own flow elsewhere.
    fn regionEntry(a: *UniformityAnalysis, fi: usize, bi: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        if (a.preludeLoop(fi, bi)) |lp| return a.loopEntryFlow(fi, lp.header, depth + 1);
        return a.funcs[fi].blocks[bi].flow;
    }

    /// A loop header's entry flow: the OR of its non-back-edge incoming
    /// contributions (the back edge arrives per-iteration and is judged by
    /// the governing condition instead).
    fn loopEntryFlow(a: *UniformityAnalysis, fi: usize, header: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const uf = &a.funcs[fi];
        var f = if (header == uf.entry_block) uf.entry_flow else false;
        for (uf.blocks[header].preds) |pi| {
            if (pi >= uf.blocks.len) continue;
            // skip the loop's own back edge (from the continue block)
            if (a.preludeLoop(fi, header)) |lp| {
                if (lp.continue_block == pi) continue;
            }
            if (a.edgeContribution(fi, pi, header, depth + 1)) f = true;
        }
        return f;
    }

    /// Is the edge from block `pi` into block `ti` a uniform edge?
    ///   OpBranch: uniform iff the source block's flow is uniform.
    ///   Conditional/switch on a UNIFORM value: same as OpBranch.
    ///   Conditional/switch on a NON-uniform value: uniform iff `ti`
    ///   postdominates `pi` (every invocation reconverges there), and then
    ///   the flow that survives is the REGION ENTRY flow (probe p10).
    fn edgeContribution(a: *UniformityAnalysis, fi: usize, pi: usize, ti: usize, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const uf = &a.funcs[fi];
        switch (uf.blocks[pi].term) {
            .branch => return uf.blocks[pi].flow,
            .cond => |c| {
                if (a.values.contains(c.cond)) return uf.blocks[pi].flow;
                return a.postdominates(fi, pi, ti) and a.regionEntry(fi, pi, depth + 1);
            },
            .swit => |s| {
                if (a.values.contains(s.sel)) return uf.blocks[pi].flow;
                return a.postdominates(fi, pi, ti) and a.regionEntry(fi, pi, depth + 1);
            },
            // a block that leaves the function has no edge into `ti` at all;
            // reaching here means the pred list disagrees with the terminator
            // (truncated/malformed input), so contribute nothing.
            .ret, .kill, .unreach => return false,
        }
    }

    /// Recompute the flow of every block of function `fi` from the current
    /// value state and entry flow; returns true when ANY block's flow changed.
    /// The outer fixpoint reads that as "not stable yet", which is sound
    /// because flow is monotone here: `entry_flow` and the value set only ever
    /// move DOWN, so a block's flow only ever moves true -> false and "any
    /// change" and "moved true -> false" are the same predicate.
    /// Flow is an OR over incoming contributions: a block is uniform when some
    /// incoming edge delivers the full invocation set (either directly, or by
    /// reconverging every path that diverged).
    fn recomputeFlow(a: *UniformityAnalysis, fi: usize) bool {
        const uf = &a.funcs[fi];
        if (uf.blocks.len == 0) return false;
        var changed = true;
        var any_changed = false;
        while (changed) {
            changed = false;
            for (uf.blocks, 0..) |*b, bi| {
                var f = if (bi == uf.entry_block) uf.entry_flow else false;
                for (b.preds) |pi| {
                    if (pi >= uf.blocks.len) continue;
                    if (a.edgeContribution(fi, pi, bi, 0)) f = true;
                }
                // Prelude blocks (loop header chain + continue block) execute
                // once PER ITERATION: their flow is the loop entry flow gated
                // by the uniformity of the trip-count conditions.
                if (a.preludeLoop(fi, bi)) |lp| {
                    var g = a.loopEntryFlow(fi, lp.header, 0);
                    for (lp.governing) |cond| {
                        if (!a.values.contains(cond)) g = false;
                    }
                    // A loop with no conditional at all (pure `while (true)`
                    // with breaks) has a condition-dependent trip count that
                    // cannot be proven uniform: stay conservative.
                    if (lp.governing.len == 0) g = false;
                    f = g;
                }
                if (f != b.flow) {
                    b.flow = f;
                    changed = true;
                    any_changed = true;
                }
            }
        }
        return any_changed;
    }

    /// Pure value-propagating ops: a result is uniform when every id operand
    /// is uniform. Deliberately EXCLUDES loads, samples, derivatives, calls
    /// and anything memory- or side-effect-ful (never uniform here).
    fn isPureValueOp(op: spirv.Op) bool {
        return switch (op) {
            .SNegate, .FNegate, .Not => true,
            .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul => true,
            .UDiv, .SDiv, .FDiv, .UMod, .SMod, .SRem, .FMod, .FRem => true,
            .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix, .OuterProduct, .Transpose, .Dot => true,
            .LogicalEqual, .LogicalNotEqual, .LogicalOr, .LogicalAnd, .LogicalNot => true,
            .IEqual, .INotEqual, .UGreaterThan, .SGreaterThan, .UGreaterThanEqual, .SGreaterThanEqual, .ULessThan, .SLessThan, .ULessThanEqual, .SLessThanEqual => true,
            .FOrdEqual, .FUnordEqual, .FOrdNotEqual, .FUnordNotEqual, .FOrdLessThan, .FUnordLessThan, .FOrdGreaterThan, .FUnordGreaterThan, .FOrdLessThanEqual, .FUnordLessThanEqual, .FOrdGreaterThanEqual, .FUnordGreaterThanEqual => true,
            .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical, .BitwiseOr, .BitwiseXor, .BitwiseAnd => true,
            .BitReverse, .BitCount, .BitFieldInsert, .BitFieldSExtract, .BitFieldUExtract => true,
            .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU, .UConvert, .SConvert, .FConvert, .QuantizeToF16, .Bitcast => true,
            .IsNan, .IsInf, .All, .Any => true,
            .CompositeConstruct, .CopyObject => true,
            .Select => true,
            else => false,
        };
    }

    /// For a phi incoming from block `pb`: was the BRANCH that left `pb`
    /// uniform? A value arriving via a diverged edge is a non-uniform
    /// SELECTION even when every incoming value is a uniform constant
    /// (probe p17).
    fn phiEdgeUniform(a: *UniformityAnalysis, fi: usize, pb: usize) bool {
        const uf = &a.funcs[fi];
        switch (uf.blocks[pb].term) {
            .cond => |c| return a.values.contains(c.cond),
            .swit => |s| return a.values.contains(s.sel),
            // an unconditional branch selects nothing, so the edge is uniform
            .branch, .ret, .kill, .unreach => return true,
        }
    }

    /// Is `root` a FUNCTION-scope variable? The #684 reachability filter is
    /// only sound for those: a Function-scope variable's contents live and
    /// die with ONE invocation, so a store cannot feed a load no CFG path
    /// leads to. A module-scope Private or Output variable PERSISTS across
    /// sequential invocations of the same function, so a store made by an
    /// earlier call can feed a load of a later one from an unreachable block
    /// (the #684 review repro), and tint poisons such reads from a
    /// non-uniform store anywhere in the module. Anything that is not a
    /// Function-scope variable (or whose definition cannot be read) keeps the
    /// flow-insensitive rule: every store counts.
    fn rootScopeIsFunction(a: *UniformityAnalysis, root: u32) bool {
        const rdef = common.getDef(a.module, root) orelse return false;
        if (rdef.words.len <= 3) return false;
        const sc: spirv.StorageClass = @enumFromInt(rdef.words[3]);
        return sc == .Function;
    }

    /// Every store into `root` that can REACH the load at `loc` (direct, and
    /// through any pointer parameter a callee received for it) wrote a uniform
    /// value from uniform flow. glslang lowers assigned locals AND helper
    /// parameters to variables, so this store rule is how uniform values
    /// actually travel (probe p24 vs p17).
    ///
    /// #684 made the rule FLOW-SENSITIVE for stores in the SAME function as
    /// the load: a store whose block cannot reach the load's block on any CFG
    /// path can never write the value the load reads, so reusing a scratch
    /// local for a later value must not poison the earlier loads. The filter
    /// argues about ONE invocation, so it is disabled for functions on a
    /// call-graph cycle, for stores made in a DIFFERENT function (cross-
    /// invocation reachability is not modelled), and for roots that are not
    /// Function-scope (see rootScopeIsFunction: module-scope Private/Output
    /// storage persists across calls of the same function, which is the same
    /// hole cross-function stores already cover).
    fn varStoresUniform(a: *UniformityAnalysis, root: u32, loc: ?UniLoc) bool {
        // The verdict is an AND, so the first failing store settles it: return
        // instead of carrying an `ok = false` through the rest of the (flat,
        // whole-module) store list.
        const l = loc orelse UniLoc{ .func = std.math.maxInt(usize), .block = 0 };
        const use_reach = l.func < a.funcs.len and !a.recursive_funcs[l.func] and a.rootScopeIsFunction(root);
        for (a.stores.items) |st| {
            if (st.root != root) continue;
            if (use_reach and st.func == l.func and !a.blockReaches(l.func, st.block, l.block)) continue;
            if (!a.values.contains(st.val)) return false;
            if (st.func >= a.funcs.len) continue;
            if (st.block >= a.funcs[st.func].blocks.len) continue;
            if (!a.funcs[st.func].blocks[st.block].flow) return false;
        }
        // stores a callee makes through the pointer it was handed for `root`:
        // only call sites that can feed the load matter (the callee's store
        // executes iff the call does, and it feeds the load iff control can
        // still reach the load after the call returns)
        for (a.arg_vars.items) |av| {
            if (av.root != root) continue;
            if (use_reach and av.caller == l.func and !a.blockReaches(l.func, av.block, l.block)) continue;
            const ci = a.func_by_id.get(av.callee) orelse return false;
            if (!a.paramStoresUniform(ci, av.pos)) return false;
        }
        return true;
    }

    /// Every store through parameter `pi` of function `fi` wrote a uniform
    /// value from uniform flow (and the parameter never aliases something
    /// unresolvable).
    fn paramStoresUniform(a: *UniformityAnalysis, fi: usize, pi: usize) bool {
        if (a.opaque_params.contains(packParamKey(fi, pi))) return false;
        for (a.param_stores.items) |st| {
            if (st.func != fi or st.param != pi) continue;
            if (!a.values.contains(st.val)) return false;
            if (st.func >= a.funcs.len) continue;
            if (st.block >= a.funcs[fi].blocks.len) continue;
            if (!a.funcs[fi].blocks[st.block].flow) return false;
        }
        return true;
    }

    /// A load through pointer parameter `pi` of function `fi` is a uniform
    /// value iff every caller handed it a variable that only ever holds
    /// uniform values (probe p23a/p23b: tint tracks the argument). `loc` is
    /// where the load sits; it only sharpens the store filter for stores into
    /// the variable made in this same function (`fi`), since the caller's
    /// stores are cross-function and count unconditionally.
    fn loadThroughParamUniform(a: *UniformityAnalysis, fi: usize, pi: usize, loc: ?UniLoc) bool {
        var seen = false;
        const fid = a.funcs[fi].id;
        for (a.arg_vars.items) |av| {
            if (av.callee != fid or av.pos != pi) continue;
            seen = true;
            if (!a.varStoresUniform(av.root, loc)) return false;
        }
        // no call site handed this parameter a variable: nothing to judge from
        return seen;
    }

    /// Classify whether `id` holds a uniform value under the CURRENT state.
    fn valueIsUniform(a: *UniformityAnalysis, id: u32) bool {
        const inst = common.getDef(a.module, id) orelse return false;
        switch (inst.op) {
            .ConstantTrue, .ConstantFalse, .Constant, .ConstantNull, .SpecConstant, .SpecConstantTrue, .SpecConstantFalse => return true,
            .ConstantComposite, .SpecConstantComposite => {
                for (inst.words[3..]) |c| {
                    if (!a.values.contains(c)) return false;
                }
                return true;
            },
            .Load => {
                // getDef only guarantees words.len >= 3; OpLoad's pointer
                // operand is words[3], so a truncated load would index past the
                // end. Conservative answer: not a uniform value.
                if (inst.words.len <= 3) return false;
                const ptr = inst.words[3];
                // #684: WHERE this load sits, for the flow-sensitive store
                // rule. An unknown function or block disables the filter
                // (every store counts), which is the conservative direction.
                const owner = a.owner_func.get(id);
                const loc: ?UniLoc = if (owner) |fi| blk: {
                    const bi = a.block_of.get(id) orelse break :blk null;
                    if (bi >= a.funcs[fi].blocks.len) break :blk null;
                    break :blk UniLoc{ .func = fi, .block = bi };
                } else null;
                // A load through a pointer parameter of the owning function
                // (glslang's parameter ABI) is judged from the arguments.
                if (owner) |fi| {
                    if (a.pointerParamOf(a.funcs[fi].params, ptr, 0)) |pi| {
                        return a.loadThroughParamUniform(fi, pi, loc);
                    }
                }
                const root = a.pointerRoot(ptr, 0) orelse return false;
                const rdef = common.getDef(a.module, root) orelse return false;
                if (rdef.words.len <= 3) return false;
                const sc: spirv.StorageClass = @enumFromInt(rdef.words[3]);
                if (a.readIsUniformStorage(root, sc)) {
                    // probe p22: every dynamic index in the chain must itself
                    // be a uniform value, or the loaded element varies.
                    return a.chainIndicesUniform(ptr, 0);
                }
                if (sc == .Function or sc == .Output or sc == .Private) {
                    return a.varStoresUniform(root, loc);
                }
                return false;
            },
            .FunctionParameter => {
                const fi = a.owner_func.get(id) orelse return false;
                const pi = a.param_index.get(id) orelse return false;
                return a.funcs[fi].param_uniform[pi];
            },
            .Phi => {
                const fi = a.owner_func.get(id) orelse return false;
                const uf = &a.funcs[fi];
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const in_val = inst.words[wi];
                    const in_parent = inst.words[wi + 1];
                    if (!a.values.contains(in_val)) return false;
                    const pb = a.label_to_block[fi].get(in_parent) orelse return false;
                    if (!uf.blocks[pb].flow) return false;
                    if (!a.phiEdgeUniform(fi, pb)) return false;
                }
                return true;
            },
            .CompositeExtract => return inst.words.len > 3 and a.values.contains(inst.words[3]),
            .VectorShuffle => {
                return inst.words.len > 4 and a.values.contains(inst.words[3]) and a.values.contains(inst.words[4]);
            },
            .CompositeInsert => {
                return inst.words.len > 4 and a.values.contains(inst.words[3]) and a.values.contains(inst.words[4]);
            },
            .ExtInst => {
                // GLSL.std.450 pure math; id operands start at words[5]. Any
                // pointer operand (Modf/Frexp) is never a uniform value, so
                // those forms refuse themselves.
                // A well-formed OpExtInst is at least 5 words (result type,
                // result id, set id, instruction literal); getDef only
                // guarantees 3, so a truncated one must answer non-uniform
                // rather than slice past the end.
                if (inst.words.len < 5) return false;
                for (inst.words[5..]) |op_id| {
                    if (!a.values.contains(op_id)) return false;
                }
                return true;
            },
            // #684: tint tracks return-value uniformity, so a call whose
            // callee only returns uniform values from uniform flow IS a
            // uniform value (probed on tint: accepted). The old blanket
            // "never uniform" silently downgraded samples gated by such
            // helpers, changing mip selection with no diagnostic. Note the
            // call SITE's flow deliberately plays no part: a uniform value
            // stays a uniform value wherever it is computed; where it is
            // STORED is already judged by the store rule.
            .FunctionCall => {
                // words[3] is the callee; getDef only guarantees 3 words, and
                // a call to a function this prepass never saw has no verdict
                // to consult: both answer non-uniform.
                if (inst.words.len <= 3) return false;
                const ci = a.func_by_id.get(inst.words[3]) orelse return false;
                return a.funcs[ci].returns_uniform;
            },
            else => {
                if (!isPureValueOp(inst.op)) return false;
                for (inst.words[3..]) |op_id| {
                    if (!a.values.contains(op_id)) return false;
                }
                return true;
            },
        }
    }

    /// Is a read through the variable `root` (storage class `sc`) a UNIFORM
    /// value for WGSL's own uniformity analysis?
    ///
    /// The answer must be decided by the ADDRESS SPACE THIS BACKEND EMITS, not
    /// by the SPIR-V storage class, because the two are not in bijection:
    ///   * StorageClass Uniform is a real UBO (`var<uniform>`, uniform read)
    ///     UNLESS the block struct carries BufferBlock, which is how glslang
    ///     targeting Vulkan 1.0 spells an SSBO -- that emits `var<storage, ...>`.
    ///   * StorageClass StorageBuffer (glslang from Vulkan 1.1 on, and tint)
    ///     is always an SSBO.
    /// A storage buffer is then a uniform read only when it is READ-ONLY:
    /// WGSL's uniformity analysis treats a `var<storage>` read as uniform and a
    /// `var<storage, read_write>` read as non-uniform (the same rule the
    /// .StorageBuffer emission arm documents). PushConstant has no WGSL address
    /// space and is emitted as a plain uniform buffer, so it is a uniform read.
    ///
    /// Deciding this from the storage class alone was wrong in BOTH directions:
    /// a Vulkan-1.0 SSBO was called uniform (the implicit sample was kept and
    /// tint rejected the module -- the very black-shader failure this prepass
    /// exists to prevent), while the SAME GLSL built for Vulkan 1.1 with
    /// `readonly` was called non-uniform and needlessly downgraded.
    fn readIsUniformStorage(a: *UniformityAnalysis, root: u32, sc: spirv.StorageClass) bool {
        switch (sc) {
            .PushConstant => return true,
            .Uniform, .StorageBuffer => {},
            else => return false,
        }
        const is_ssbo = if (sc == .StorageBuffer) true else blk: {
            const vdef = common.getDef(a.module, root) orelse break :blk false;
            if (vdef.words.len <= 1) break :blk false;
            const ptr_inst = common.getDef(a.module, vdef.words[1]) orelse break :blk false;
            if (ptr_inst.op != .TypePointer or ptr_inst.words.len <= 3) break :blk false;
            break :blk hasDec(a.decorations, arrayElementType(a.module, ptr_inst.words[3]), .buffer_block);
        };
        if (!is_ssbo) return true; // a real UBO
        return hasDec(a.decorations, root, .non_writable);
    }

    /// Every dynamic index of an access chain rooted at `ptr_id` is a
    /// uniform value (probe p22).
    fn chainIndicesUniform(a: *UniformityAnalysis, ptr_id: u32, depth: u32) bool {
        if (depth > max_flow_depth) return false;
        const inst = common.getDef(a.module, ptr_id) orelse return false;
        switch (inst.op) {
            .Variable => return true,
            .AccessChain => {
                // base operand at words[3], indices from words[4]; getDef only
                // guarantees 3 words, so a truncated chain answers non-uniform
                // rather than indexing past the end.
                if (inst.words.len <= 3) return false;
                for (inst.words[4..]) |idx| {
                    if (!a.values.contains(idx)) return false;
                }
                return a.chainIndicesUniform(inst.words[3], depth + 1);
            },
            .CopyObject => return if (inst.words.len > 3) a.chainIndicesUniform(inst.words[3], depth + 1) else false,
            else => return false,
        }
    }
};

/// pack a (function, block) pair into one key for the prelude map
fn packFlowKey(fi: usize, bi: usize) u64 {
    return (@as(u64, @intCast(fi)) << 32) | @as(u64, @intCast(bi));
}

/// pack a (function, parameter index) pair into one key
fn packParamKey(fi: usize, pi: usize) u64 {
    return (@as(u64, @intCast(fi)) << 32) | @as(u64, @intCast(pi));
}

/// Raw OpLoopMerge data recorded during parse, resolved once the function's
/// blocks all exist.
const UniLoopMerge = struct { merge: u32, cont: u32 };

/// Compute the set of RESULT ids of the UNIFORMITY-GATED builtins (the
/// implicit-Lod samples AND, since #685, the nine derivative opcodes) that sit
/// in non-uniform control flow in the generated WGSL. The emitter consults the
/// map at each gated builtin: a marked sample is LOWERED to the uniformity-safe
/// explicit-Level form, a marked derivative is REFUSED (there is no lowered
/// form for one; see recordUnsupportedNonuniformDerivative). Empty (not an
/// error) for the common module with neither.
///
/// The error set is written out rather than inferred. This function introduced
/// a NEW error name into a file whose call chain is inferred end to end, and an
/// inferred set gives nobody downstream a reason to notice: spelling it here is
/// what makes adding another one a visible, reviewable change (and what pins
/// `UniformityAnalysisDidNotConverge` as the ONLY non-OOM failure this prepass
/// can produce, which is what the cli.zig detail gate relies on).
fn computeNonuniformGatedBuiltinIds(
    arena: std.mem.Allocator,
    module: *const ParsedModule,
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
) error{ OutOfMemory, UniformityAnalysisDidNotConverge }!std.AutoHashMap(u32, void) {
    var out = std.AutoHashMap(u32, void).init(arena);
    var a = UniformityAnalysis{
        .module = module,
        .decorations = decorations,
        .arena = arena,
        .funcs = &.{},
        .func_by_id = std.AutoHashMap(u32, usize).init(arena),
        .label_to_block = &.{},
        .loops_of = &.{},
        .owner_func = std.AutoHashMap(u32, usize).init(arena),
        .block_of = std.AutoHashMap(u32, usize).init(arena),
        .param_index = std.AutoHashMap(u32, usize).init(arena),
        .values = std.AutoHashMap(u32, void).init(arena),
        .opaque_params = std.AutoHashMap(u64, void).init(arena),
        .prelude_of = std.AutoHashMap(u64, u64).init(arena),
        .loop_merges = std.AutoHashMap(u32, UniLoopMerge).init(arena),
        .visited = std.AutoHashMap(usize, void).init(arena),
    };
    try a.parse();
    if (a.funcs.len == 0) return out;

    // Optimistic init: every id is a uniform value until proven otherwise.
    // Every component of the fixpoint below only ever moves DOWN, so it
    // terminates; the round cap is paranoia against hostile input.
    for (module.id_defs, 0..) |def, id| {
        if (def != null) try a.values.put(@intCast(id), {});
    }

    // Round cap: paranoia against hostile input, NOT an expected exit. Every
    // fixpoint component only moves DOWN, so convergence is bounded by the id
    // count; a module that still has not settled after 1000 rounds means an
    // invariant broke. Exiting quietly there would ship the LAST round's
    // half-settled answer, which is OPTIMISTIC (values still marked uniform
    // that another round would have cleared) and so can keep an implicit
    // sample tint rejects: the exact silent-wrong this prepass exists to
    // prevent. Fail loud instead.
    //
    // Why fail loud and not fail SAFE (mark every implicit sample non-uniform
    // and carry on)? Fail-safe would compile, but it would silently change mip
    // selection for every sample in the module -- a visibly different image
    // from a bug nobody was told about, which is the failure mode this whole
    // prepass exists to remove. A refusal is loud, actionable and rare (no
    // input has ever reached it), so it is the honest trade here.
    const max_rounds: u32 = 1000;
    // Per-round scratch, hoisted OUT of the loop: `arena` never frees, so
    // allocating these inside it burned one fresh allocation per round each,
    // up to 1000 of them on a module that runs the cap out. Both are fully
    // reset at the top of the step that uses them, so hoisting is behaviour
    // preserving.
    var to_remove = std.ArrayListUnmanaged(u32).empty;
    const new_flow = try arena.alloc(bool, a.funcs.len);
    var rounds: u32 = 0;
    var stable = false;
    while (!stable and rounds < max_rounds) : (rounds += 1) {
        stable = true;
        // 1. block flows from the current values and entry flows
        for (0..a.funcs.len) |fi| {
            if (a.recomputeFlow(fi)) stable = false;
        }
        // 2. value uniformity from the current values and flows
        {
            to_remove.clearRetainingCapacity();
            var vit = a.values.iterator();
            while (vit.next()) |entry| {
                if (!a.valueIsUniform(entry.key_ptr.*)) try to_remove.append(arena, entry.key_ptr.*);
            }
            if (to_remove.items.len > 0) {
                stable = false;
                for (to_remove.items) |id| _ = a.values.remove(id);
            }
        }
        // 3. a callee's ENTRY flow is the AND of its call sites' block flows
        //    (probe p11/p12). The entry point starts uniform and stays so.
        {
            @memset(new_flow, true);
            for (a.funcs, 0..) |caller, fi| {
                for (caller.calls) |call| {
                    const ci = a.func_by_id.get(call.callee) orelse continue;
                    if (ci == fi) continue; // self-recursion adds no information
                    if (!caller.blocks[call.block].flow) new_flow[ci] = false;
                }
            }
            for (a.funcs, 0..) |uf, fi| {
                if (uf.is_entry_point) continue;
                if (new_flow[fi] != uf.entry_flow) {
                    a.funcs[fi].entry_flow = new_flow[fi];
                    stable = false;
                }
            }
        }
        // 4. a PARAMETER is a uniform value iff every call site passes a
        //    uniform argument (probe p23a/p23b)
        for (a.funcs, 0..) |caller, fi| {
            for (caller.calls) |call| {
                const ci = a.func_by_id.get(call.callee) orelse continue;
                if (ci == fi) continue;
                const callee = &a.funcs[ci];
                for (call.args, 0..) |arg, ai| {
                    if (ai >= callee.params.len) break;
                    if (!a.values.contains(arg) and callee.param_uniform[ai]) {
                        callee.param_uniform[ai] = false;
                        stable = false;
                    }
                }
            }
        }
        // 5. (#684) a function's RESULT is a uniform value iff every
        //    OpReturnValue returns a uniform value FROM A BLOCK WITH UNIFORM
        //    FLOW. The block half is load-bearing, probed on tint: a uniform
        //    value returned from a DIVERGED arm is a non-uniform result (which
        //    return fired was selected by diverged flow, the same selection
        //    rule as a phi edge, probe p17), while a return after a
        //    reconverged if, or selected by a uniform condition, stays
        //    uniform. Value-only would be unsound here. The flow consulted is
        //    the callee's own, whose entry is the AND of its call sites, so a
        //    helper with one non-uniform call site has its result called
        //    non-uniform everywhere (tint would keep it at the uniform sites);
        //    that costs keeps, never correctness. Functions on a call-graph
        //    cycle keep the pre-#684 verdict: never a uniform result.
        for (a.funcs, 0..) |*uf, fi| {
            if (a.recursive_funcs[fi]) {
                if (uf.returns_uniform) {
                    uf.returns_uniform = false;
                    stable = false;
                }
                continue;
            }
            var ru = true;
            for (uf.returns) |r| {
                if (!a.values.contains(r.val)) {
                    ru = false;
                    break;
                }
                if (r.block >= uf.blocks.len or !uf.blocks[r.block].flow) {
                    ru = false;
                    break;
                }
            }
            if (ru != uf.returns_uniform) {
                uf.returns_uniform = ru;
                stable = false;
            }
        }
    }

    if (!stable) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "the WGSL uniformity prepass did not converge in {d} rounds. Every component of that fixpoint only moves DOWN, so this is an INTERNAL INVARIANT failure in zioshade, not a problem with your shader. Workaround: none; please file a bug against zioshade with the shader (or the SPIR-V) that produced this.", .{max_rounds}) catch null;
        return error.UniformityAnalysisDidNotConverge;
    }

    for (a.funcs) |uf| {
        for (uf.samples) |s| {
            if (!uf.blocks[s.block].flow) try out.put(s.result, {});
        }
        // #685: same verdict, different consumer decision. A derivative in
        // non-uniform flow has no lowered form (WGSL offers no
        // explicit-derivative spelling to pin anything to), so its result id
        // goes into the SAME map and the derivative arms of the emitter
        // refuse on it rather than downgrade.
        for (uf.derivatives) |d| {
            if (!uf.blocks[d.block].flow) try out.put(d.result, {});
        }
    }
    return out;
}

fn emitBody(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), func_idx: usize, w_out: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, inout_return: ?[]const u8, skip_store_target: ?u32, skip_store_targets: ?*const std.AutoHashMap(u32, void), wrapped_uniform_arrays: *const std.AutoHashMap(u32, void), wrapped_members: *const WrappedUniformMemberMap, matrix_outputs: *const std.AutoHashMap(u32, MatrixOutput), atomic_vars: *const std.AutoHashMap(u32, void), atomic_fields: *const AtomicFieldMap, nonuniform_gated: *const std.AutoHashMap(u32, void), early_return: EarlyReturnMode, subpass_fragcoord_name: ?[]const u8, walk: ?*WalkCtx, range: ?RangeCtx) !void {
    if (range) |r| {
        if (r.depth >= max_region_depth) return error.UnsupportedRegionDepth;
    }
    // #post-loop-header-use: `w` below is a one-instruction pending buffer over
    // the real writer (`w_out`). The emit loop flushes it at the top of every
    // instruction so a hoisted loop value's `let` declaration can be rewritten
    // into an assignment to the `var` declared above the loop BEFORE it is
    // committed. Behavior is byte-identical when nothing is hoisted.
    var hoist_pending: std.ArrayList(u8) = .empty;
    defer hoist_pending.deinit(alloc);
    const w = HoistWriter(@TypeOf(w_out)){ .real = w_out, .pending = &hoist_pending, .alloc = alloc };
    var indent: u32 = 1; // base function body indentation (4 spaces)
    if (range) |r| indent = r.indent; // region mode: match the enclosing case body

    // Helper to write current indentation
    const writeInd = struct {
        fn write(writer: anytype, depth: u32) !void {
            try writeIndentStatic(writer, depth);
        }
    }.write;
    // #wgsl-region-mode: fresh context at every existing (top-level) call;
    // a region-mode recursive call passes the parent's -- see WalkCtx.
    const prepass = walk == null;
    var ctx_storage: WalkCtx = .{
        .inline_loads = std.AutoHashMap(u32, void).init(arena),
        .declared_local_names = std.StringHashMap(void).init(arena),
        .store_targets = std.AutoHashMap(u32, void).init(arena),
        .extract_old_names = std.AutoHashMap(u32, []const u8).init(arena),
        .late_renamed_extracts = std.AutoHashMap(u32, void).init(arena),
        .dead_conditions = std.AutoHashMap(u32, void).init(arena),
        .dead_arith = std.AutoHashMap(u32, void).init(arena),
        .inline_exprs = std.AutoHashMap(u32, []const u8).init(arena),
        .hoisted_ids = std.AutoHashMap(u32, void).init(arena),
        .loop_hoists = std.AutoHashMap(usize, std.ArrayList(u32)).init(arena),
        .dead_extracts = std.AutoHashMap(u32, void).init(arena),
        .declared_merge_phis = std.AutoHashMap(u32, void).init(arena),
    };
    const ctx: *WalkCtx = if (walk) |wp| wp else &ctx_storage;

    // Skip function declaration instructions
    var i: usize = func_idx + 1;
    if (range) |r| {
        // Region mode: enter directly past the region's opening Label.
        i = r.start_idx;
    } else {
        // Skip FunctionParameter instructions (parameters declared in function signature)
        while (i < module.instructions.len) : (i += 1) {
            const inst = module.instructions[i];
            if (inst.op == .Label) {
                i += 1;
                break;
            }
            if (inst.op == .FunctionParameter) continue;
            break;
        }
    }

    // Index of the function's LAST OpReturn — the terminator of the final block,
    // which the wrapper turns into the trailing output-struct return. Any earlier
    // OpReturn (or one nested in a selection/loop) is an EARLY return that must
    // actually exit; see the `.Return` arm.
    var last_return_idx: usize = 0;
    {
        var ri: usize = func_idx + 1;
        while (prepass and ri < module.instructions.len) : (ri += 1) {
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
    // #wgsl-else-clobber: pending_false_label must be saved/restored across nested
    // ifs. Previously a nested (no-else) if overwrote the enclosing if's
    // pending_false_label to null, so the enclosing then-block's terminating
    // OpBranch never emitted `} else {` and the else-body leaked into the
    // then-branch (silent-wrong). This stack mirrors merge_stack push/pop 1:1.
    var false_label_stack = std.ArrayList(?u32).initCapacity(arena, 8) catch return;
    defer false_label_stack.deinit(arena);

    // Loop state tracking
    var loop_merge_label: ?u32 = null;
    var loop_continue_label: ?u32 = null;
    var loop_header_label: ?u32 = null;
    var in_loop: bool = false;
    // Region mode: inherit the enclosing loop context.
    if (range) |r| {
        if (r.loop_continue != null or r.loop_merge != null) {
            in_loop = true;
            loop_continue_label = r.loop_continue;
            loop_merge_label = r.loop_merge;
        }
    }
    var in_continue_block: bool = false;
    const PhiUpdate = struct { result_id: u32, value_id: u32 };
    var phi_updates = std.ArrayList(PhiUpdate).initCapacity(arena, 8) catch return;
    defer phi_updates.deinit(arena);
    // Selection phi: [merge_label] → list of (result_id, value_id, predecessor_label)
    {
        var si: usize = func_idx + 1;
        while (prepass and si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .Phi and scan_inst.words.len >= 7) {
                // Check if this phi belongs to a loop header (skip — loop phis are handled separately)
                var is_loop_phi = false;
                // #phi-peek-window: a loop-header phi's OpLoopMerge can sit far past
                // the phi (graphicsfuzz_015 has a 30-instruction header body between
                // them). The old 30-instruction cap misread such a phi as a SELECTION
                // phi: ctx.sel_phis then contained it, the .Phi arm suppressed its `var`
                // (already_declared), and the branch-to-header emitted a bare update
                // for a never-declared identifier (naga "no definition in scope").
                // The Label/SelectionMerge/FunctionEnd stops below already bound the
                // scan to the phi's own block, so widening the horizon cannot reach a
                // LoopMerge of a LATER block; 256 covers any real header.
                var pk: usize = si + 1;
                while (prepass and pk < @min(si + 256, module.instructions.len)) : (pk += 1) {
                    if (module.instructions[pk].op == .LoopMerge) {
                        is_loop_phi = true;
                        break;
                    }
                    if (module.instructions[pk].op == .SelectionMerge or module.instructions[pk].op == .Label or module.instructions[pk].op == .FunctionEnd) break;
                }
                if (is_loop_phi) continue;

                // Find the merge label this phi belongs to (the label of the current block)
                var merge_label: ?u32 = null;
                var li: usize = si;
                while (prepass and li > func_idx) : (li -= 1) {
                    if (module.instructions[li].op == .Label and module.instructions[li].words.len > 1) {
                        merge_label = module.instructions[li].words[1];
                        break;
                    }
                }
                if (merge_label) |ml| {
                    // Parse all (value, predecessor) pairs
                    var pi: usize = 3;
                    while (prepass and pi + 1 < scan_inst.words.len) : (pi += 2) {
                        const val_id = scan_inst.words[pi];
                        const pred_id = scan_inst.words[pi + 1];
                        const gop = ctx.sel_phis.getOrPut(arena, ml) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(SelPhi).initCapacity(arena, 2) catch continue;
                        // append (not appendAssumeCapacity): a merge label accumulates one
                        // entry per (value,predecessor) pair across ALL phis at that merge —
                        // 3 phis × 2 predecessors = 6 entries (phi3_vars.frag), and a switch
                        // phi has one pair per case — both exceed the initial capacity of 2,
                        // which previously overflowed the assumed-capacity append → panic.
                        gop.value_ptr.append(arena, .{ .result_id = scan_inst.words[2], .value_id = val_id, .pred_label = pred_id }) catch continue;
                    }
                }
            }
        }
    }
    var loop_stack = std.ArrayList(struct { merge: u32, cont: u32, header: u32, phi_start: usize, phi_end: usize, emit_continuing: bool, continuing_open: bool }).initCapacity(arena, 4) catch return;
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
    {
        var si: usize = func_idx + 1;
        while (prepass and si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            // Record the defining opcode for result IDs
            if (scan_inst.words.len > 2) {
                // Most opcodes: words[1]=type, words[2]=result
                // Record only for opcodes that produce named results
                if (scan_inst.op != .Label and scan_inst.op != .FunctionParameter) {
                    try ctx.def_op.put(arena, scan_inst.words[2], scan_inst.op);
                }
            }
            // Count uses of each ID referenced in the instruction
            for (scan_inst.words[@min(1, scan_inst.words.len)..]) |word| {
                // Count uses of each ID referenced in the instruction
                const entry = try ctx.use_count.getOrPutValue(arena, word, 0);
                entry.value_ptr.* += 1;
            }
        }
    }

    // For single-use OpLoad results, inline the source pointer name
    // This eliminates unnecessary 'let vN = ptr;' declarations
    // BUT: don't inline if the pointer is also a Store target (to preserve load-before-store semantics)
    // Names already used by an emitted function-local `var`, to dedup collisions:
    // glslang can emit two DISTINCT OpVariables with the SAME OpName string (e.g. the
    // compiler-generated `indexable` temps for dynamic indexing of a const array),
    // which would produce a WGSL "redefinition". (#170)
    // Build set of pointer IDs that are Store targets in this function
    {
        var si: usize = func_idx + 1;
        while (prepass and si < module.instructions.len) : (si += 1) {
            const scan_inst = module.instructions[si];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .Store and scan_inst.words.len > 1) {
                ctx.store_targets.put(scan_inst.words[1], {}) catch {};
            }
        }
    }

    // #170 (function-local var name collision): glslang can emit two DISTINCT
    // OpVariables with the SAME OpName (e.g. "icoord"), which would collide in
    // WGSL. The emission loop's .Variable case deduped these by appending _1/_2
    // and writing the unique name back to `names` -- but that ran AFTER every
    // name-resolution pre-scan below (load propagation, AccessChain pre-scan/
    // refresh, and the arithmetic inline-expression pre-scan), so any frozen
    // expression that captured the colliding var name held the PRE-mangle name
    // ("icoord") while direct emission used the POST-mangle name ("icoord_1"):
    // the same value under two names, and the stale name leaked wherever the
    // result was re-inlined (naga "unknown identifier", silent-wrong). Running
    // the SAME counter-suffix dedup HERE -- before any pre-scan reads a var name
    // -- makes decl and every use agree. The emission .Variable case becomes a
    // plain emit (names[rid] is already unique).
    {
        var vdi: usize = func_idx + 1;
        while (prepass and vdi < module.instructions.len) : (vdi += 1) {
            const dvinst = module.instructions[vdi];
            if (dvinst.op == .FunctionEnd) break;
            if (dvinst.op != .Variable or dvinst.words.len < 4) continue;
            const dsc: spirv.StorageClass = @enumFromInt(dvinst.words[3]);
            if (dsc != .Function) continue; // Private/Output/Input handled elsewhere
            const drid = dvinst.words[2];
            var dvn = names.get(drid) orelse "v";
            if (ctx.declared_local_names.contains(dvn)) {
                var dn: u32 = 1;
                var duniq = std.fmt.allocPrint(alloc, "{s}_{d}", .{ dvn, dn }) catch continue;
                while (prepass and ctx.declared_local_names.contains(duniq)) {
                    alloc.free(duniq);
                    dn += 1;
                    duniq = std.fmt.allocPrint(alloc, "{s}_{d}", .{ dvn, dn }) catch continue;
                }
                if (names.fetchPut(drid, duniq) catch null) |old| alloc.free(old.value);
                dvn = duniq;
            }
            ctx.declared_local_names.put(arena.dupe(u8, dvn) catch continue, {}) catch continue;
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
        var it = ctx.def_op.iterator();
        while (if (prepass) it.next() else null) |entry| {
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
            if (!unconditional and ctx.store_targets.contains(ptr_id)) continue;
            const ptr_name = names.get(ptr_id) orelse continue;
            if (ptr_name.len == 0) continue;
            const current_name = names.get(result_id) orelse "";
            if (std.mem.eql(u8, ptr_name, current_name)) continue; // already aligned
            const name_copy = try alloc.dupe(u8, ptr_name);
            if (try names.fetchPut(result_id, name_copy)) |old| alloc.free(old.value);
            try ctx.inline_loads.put(result_id, {});
        }
    }

    // Pre-scan: process AccessChain instructions to set names before expression inlining
    // Without this, inline expressions reference raw names like v27 instead of v15.colors[v25]
    {
        var aci: usize = func_idx + 1;
        while (prepass and aci < module.instructions.len) : (aci += 1) {
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
    // `ctx.inline_loads` and `ctx.store_targets` were set up before the AccessChain
    // pre-scan above (so direct immutable-variable loads are named first). This
    // loop covers the remaining loads — notably loads of AccessChain results,
    // whose names depend on the expressions that pre-scan built.
    {
        var it = ctx.def_op.iterator();
        while (if (prepass) it.next() else null) |entry| {
            if (entry.value_ptr.* == .Load or entry.value_ptr.* == .CopyObject) {
                const result_id = entry.key_ptr.*;
                // Already handled by the direct-variable pre-pass — its name and
                // inline status are final; re-running would self-assignment-rename it.
                if (ctx.inline_loads.contains(result_id)) continue;
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
                        if (ctx.store_targets.contains(ptr_id)) continue;
                        // #wgsl-atomic-field: a load of an SSBO atomic field must
                        // NOT be inlined to the bare access expression (e.g. "b.x"):
                        // the field is declared atomic<T>, so a plain read is
                        // naga-invalid ("atomic variables cannot be accessed
                        // directly"). Leave the default result name so the OpLoad
                        // handler materializes a proper `let vN = atomicLoad(&b.x);`.
                        if (resolveAtomicFieldAccess(module, ptr_id, atomic_fields) != null) continue;
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
                            try ctx.inline_loads.put(result_id, {});
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
    {
        var sni: usize = func_idx + 1;
        while (prepass and sni < module.instructions.len) : (sni += 1) {
            const sn = module.instructions[sni];
            if (sn.op == .FunctionEnd) break;
            if (sn.op == .CompositeExtract and sn.words.len > 2) {
                if (names.get(sn.words[2])) |old| {
                    // Use arena: ctx.extract_old_names is arena-allocated and only
                    // read within this function, so the value strings should
                    // live in arena too (otherwise they leak when arena is freed).
                    ctx.extract_old_names.put(sn.words[2], arena.dupe(u8, old) catch continue) catch {};
                }
            }
        }
    }

    // Pre-scan: inline single-use CompositeExtract results (v15 = v14.x → rename v15 to v14.x)
    // Extracts this pre-scan declines to rename, but which the emission path renames
    // anyway. Their names are NOT final here, so an expression cached over them would
    // freeze a name that later changes. See the ctx.inline_exprs builder below.
    // Process in instruction order so parent extracts are renamed before children
    {
        var ii: usize = func_idx + 1;
        while (prepass and ii < module.instructions.len) : (ii += 1) {
            const scan_inst = module.instructions[ii];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op != .CompositeExtract or scan_inst.words.len <= 4) continue;
            // Leave OpIAddCarry/OpISubBorrow member extracts alone — their struct
            // result is never emitted, so inlining would rename them to
            // `<unemitted-result>.<member>` (an undefined identifier). They are
            // recomputed from the operands in the CompositeExtract arm. (#170)
            if (getDef(module, scan_inst.words[3])) |src_def| {
                if (isAddCarryOrSubBorrow(src_def.op)) continue;
                // A null-constant source folds to the zero literal of the extract's
                // own result type (naga's `return Struct();` shape: the io struct is
                // never declared, so `v3().x` would be an undefined identifier).
                if (src_def.op == .ConstantNull) {
                    if (zeroLiteralOfType(module, scan_inst.words[1], names, alloc)) |z| {
                        if (try names.fetchPut(scan_inst.words[2], z)) |old| alloc.free(old.value);
                        try ctx.inline_loads.put(scan_inst.words[2], {});
                    }
                    continue;
                }
            }
            const result_id = scan_inst.words[2];
            const uses = ctx.use_count.get(result_id) orelse 0;
            if (uses > 3 or uses < 2) continue;
            // #rm-extract: an extract that reaches a row-major matrix member
            // must NOT be renamed to a bare `c.member` expression here -- a RAW
            // (buffer-loaded) source needs transpose(...) compensation, which
            // only the CompositeExtract arm emits, and an UNKNOWN source
            // (function call, select) must reach that arm to fail loudly.
            // Renaming adds the id to ctx.inline_loads, which SKIPS the arm, so
            // skipping the rename is what routes it there. A LOGICAL source
            // (CompositeConstruct of the decorated type) renames safely.
            if (findRowMajorExtract(module, scan_inst.words[3], scan_inst.words[4..]) != null) {
                if (valueBytesProvenance(module, scan_inst.words[3], 0) != .logical) continue;
            }
            {
                const source_id = scan_inst.words[3];
                const source_def = getDef(module, source_id);
                if (source_def) |sd| {
                    if (sd.op == .Load or sd.op == .CopyObject) {
                        if (sd.words.len > 3) {
                            const ptr_def = getDef(module, sd.words[3]);
                            if (ptr_def) |pd| {
                                if (pd.op == .AccessChain) {
                                    ctx.late_renamed_extracts.put(result_id, {}) catch {};
                                    continue; // skip
                                }
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
                            // frexp/modf struct result → WGSL builtin fields, not `._N`. (#170)
                            if (frexpModfField(module, scan_inst.words[3], idx)) |fld| break :blk fld;
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
                    try ctx.inline_loads.put(result_id, {});
                } else {
                    // No rename needed — release the buffer we just allocated.
                    alloc.free(new_name_buf);
                }
            }
        }
    }

    // Fix stale names: replace old extract names with new ones in cached
    // expression strings (names values; inline_exprs is empty at this point).
    // Extracted into fixStaleExtractNames so the deferred loop-header replay
    // can re-run it AFTER its own renames.
    if (prepass) try fixStaleExtractNames(names, ctx, alloc, arena);

    // Pre-scan: identify dead CompositeExtract results that will be absorbed by swizzle optimization

    {
        var si: usize = func_idx + 1;
        while (prepass and si < module.instructions.len) : (si += 1) {
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
                // or an ARRAY source (`a[0], a[1], …`) must NOT have its element
                // extracts marked dead here — the emit path's matching
                // `src_is_aggregate` guard keeps them as separate args, so dropping
                // them would leave those args referencing undefined names. (#170)
                var src_is_aggregate = false;
                if (lead_source) |ls| {
                    if (resolveTypeOf(module, ls)) |st| {
                        if (getDef(module, st)) |sd2| {
                            if (sd2.op == .TypeStruct or sd2.op == .TypeArray or sd2.op == .TypeRuntimeArray) src_is_aggregate = true;
                        }
                    }
                }
                // The emit path additionally refuses to collapse when the RESULT is a
                // struct or a matrix, and this pre-scan must agree with it exactly. It
                // did not: for `mat4x4(m[0], m[1], m[2], m[3])` the pre-scan marked the
                // four column extracts dead while the emit path kept them as separate
                // arguments, so the arguments referenced names nothing ever defined
                // (graphicsfuzz_056: `mat4x4f(v20, v21, v22, v23)` with no v20..v23).
                // A matrix has no swizzle form for its columns, so there is nothing to
                // collapse into in the first place.
                const dead_is_struct_result = isStructType(module, scan_inst.words[1]);
                const dead_is_matrix_result = isMatrixType(module, scan_inst.words[1]);
                if (lead_count >= 2 and lead_source != null and !src_is_aggregate and !dead_is_struct_result and !dead_is_matrix_result) {
                    // Mark the leading CompositeExtract results as dead
                    // ONLY if they're not used elsewhere (single use absorbed by swizzle)
                    for (scan_inst.words[3..], 0..) |comp_id, ci| {
                        if (ci >= lead_count) break;
                        const ext_uses = ctx.use_count.get(comp_id) orelse 0;
                        // ctx.use_count includes definition (1) + uses. For single-use, total = 2.
                        // Only mark dead if this CompositeConstruct is the sole consumer.
                        if (ext_uses <= 2) {
                            ctx.dead_extracts.put(comp_id, {}) catch {};
                        }
                    }
                }
            }
        }
    }

    // Pre-scan: identify dead conditions that will be inlined into BranchConditional
    {
        var ci: usize = func_idx + 1;
        while (prepass and ci < module.instructions.len) : (ci += 1) {
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
                while (prepass and li > func_idx) : (li -= 1) {
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
                        markDeadConditions(module, cond_id, &ctx.dead_conditions, 0);
                    }
                }
            }
        }
    }

    // Refresh AccessChain names (and the loads that inline them) before building
    // inline expressions below. The AccessChain pre-scan above ran BEFORE index
    // loads were renamed to their source expressions, so a DYNAMIC index froze the
    // raw temp name (`u.v4[v15]` instead of `u.v4[u.n]`): buildAccessExprPlain
    // resolved the index via `names.get(index_id)`, and at that point the index
    // load still carried its SSA temp name. The emission loop rebuilds AccessChain
    // names correctly, but ctx.inline_exprs (built just below) captures `names` NOW and
    // would otherwise freeze the stale index — which then reappears verbatim wherever
    // that arithmetic result is re-inlined (naga-rejected undefined identifier).
    // Rebuilding here, after all load/extract renames, is the same operation the
    // emission loop performs; doing it early makes the two agree.
    {
        var aci: usize = func_idx + 1;
        while (prepass and aci < module.instructions.len) : (aci += 1) {
            const ac_inst = module.instructions[aci];
            if (ac_inst.op == .FunctionEnd) break;
            if (ac_inst.op != .AccessChain or ac_inst.words.len <= 3) continue;
            const result_id = ac_inst.words[2];
            var expr = buildAccessExpr(module, names, ac_inst.words[3], ac_inst.words[4..], alloc, wrapped_members) catch continue;
            if (std.mem.indexOf(u8, expr, "._wrapped_[") != null) {
                const with_x = std.fmt.allocPrint(alloc, "{s}.x", .{expr}) catch {
                    alloc.free(expr);
                    continue;
                };
                alloc.free(expr);
                expr = with_x;
            }
            const cur = names.get(result_id);
            if (expr.len == 0 or (cur != null and std.mem.eql(u8, cur.?, expr))) {
                alloc.free(expr);
                continue;
            }
            if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
        }
        // Re-propagate refreshed AccessChain names into the immutable loads that
        // were inlined to them (a load of an AccessChain pointer takes the chain's
        // name); their frozen names must follow the refresh too.
        var it = ctx.def_op.iterator();
        while (if (prepass) it.next() else null) |entry| {
            if (entry.value_ptr.* != .Load and entry.value_ptr.* != .CopyObject) continue;
            const result_id = entry.key_ptr.*;
            if (!ctx.inline_loads.contains(result_id)) continue;
            const load_inst = getDef(module, result_id) orelse continue;
            if (load_inst.words.len <= 3) continue;
            const ptr_id = load_inst.words[3];
            if (ctx.store_targets.contains(ptr_id)) continue;
            const ptr_inst = getDef(module, ptr_id) orelse continue;
            if (ptr_inst.op != .AccessChain) continue;
            const ptr_name = names.get(ptr_id) orelse continue;
            const cur = names.get(result_id) orelse "";
            if (std.mem.eql(u8, cur, ptr_name)) continue;
            const copy = alloc.dupe(u8, ptr_name) catch continue;
            if (try names.fetchPut(result_id, copy)) |old| alloc.free(old.value);
        }
    }

    // Pre-scan: build inline expressions for single-use arithmetic operations
    // This eliminates chains like: let v13 = v12 * 6.0; let v17 = v13 + v16; → inline v13 into v17
    {
        // Build set of IDs used as Store operands (these feed mutable vars, don't inline)
        var store_operands = std.AutoHashMap(u32, void).init(arena);
        var si: usize = func_idx + 1;
        while (prepass and si < module.instructions.len) : (si += 1) {
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
        while (prepass and ii < module.instructions.len) : (ii += 1) {
            const scan_inst = module.instructions[ii];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.words.len < 3) continue;
            const result_id = scan_inst.words[2];
            if (!isInlineableArithOp(scan_inst.op)) continue;
            const uses = ctx.use_count.get(result_id) orelse 0;
            if (uses != 2) continue;
            if (ctx.dead_extracts.contains(result_id) or ctx.dead_conditions.contains(result_id)) continue;
            if (store_operands.contains(result_id)) continue;
            // buildInlineExpr resolves operands through `names` and freezes the result.
            // An operand the extract pre-scan declined to rename gets renamed anyway
            // during emission, so the cached string would keep a name that no longer
            // exists. graphicsfuzz_081 emitted `let v41 = v18[v30].x + v18[v30].z;` and
            // then re-expanded the same add at its use site as `(v35 + v40)`, naming two
            // temps that were never bound. Declining to cache is always safe: the `let`
            // binding is emitted regardless, so the use site falls back to it. Same class
            // as the AccessChain rebuild above, which exists for exactly this reason.
            {
                var oi: usize = 3;
                var operand_renamed_late = false;
                while (prepass and oi < scan_inst.words.len) : (oi += 1) {
                    if (ctx.late_renamed_extracts.contains(scan_inst.words[oi])) {
                        operand_renamed_late = true;
                        break;
                    }
                }
                if (operand_renamed_late) continue;
            }
            const expr = buildInlineExpr(module, names, &ctx.inline_exprs, result_id, arena, 0) orelse continue;
            try ctx.inline_exprs.put(result_id, expr);
        }
        // Second pass: find dead bindings (where the single user is also dead)
        // Fixpoint: keep iterating until no new dead IDs are found
        var changed = true;
        while (prepass and changed) {
            changed = false;
            var fp_it = ctx.inline_exprs.iterator();
            while (if (prepass) fp_it.next() else null) |entry| {
                const result_id = entry.key_ptr.*;
                if (ctx.dead_arith.contains(result_id)) continue; // already dead
                const uses = ctx.use_count.get(result_id) orelse 0;
                if (uses != 2) continue;
                // Find the single user instruction
                var user_is_dead = false;
                var fi: usize = func_idx + 1;
                while (prepass and fi < module.instructions.len) : (fi += 1) {
                    const finst = module.instructions[fi];
                    if (finst.op == .FunctionEnd) break;
                    if (finst.words.len > 2 and finst.words[2] == result_id) continue;
                    var found = false;
                    for (finst.words[@min(3, finst.words.len)..]) |fw| {
                        if (fw == result_id) {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        if (finst.words.len > 2) {
                            const user_result = finst.words[2];
                            // User is dead if it's already in ctx.dead_arith
                            if (ctx.dead_arith.contains(user_result)) {
                                user_is_dead = true;
                            }
                        }
                        break;
                    }
                }
                if (user_is_dead) {
                    ctx.dead_arith.put(result_id, {}) catch {};
                    changed = true;
                }
            }
        }
        // Revive dead IDs whose names are referenced in surviving inline expressions
        // If a dead ID's name appears in an ctx.inline_exprs value, the reference would be
        // undeclared, so we must keep the binding
        {
            var revive_blk = std.ArrayList(u32).initCapacity(arena, 16) catch unreachable;
            var revive = &revive_blk;
            var re_it = ctx.dead_arith.iterator();
            while (if (prepass) re_it.next() else null) |entry| {
                const dead_id = entry.key_ptr.*;
                const dead_name = names.get(dead_id) orelse continue;
                if (dead_name.len < 2) continue; // skip short names like "v"
                // Check if any ctx.inline_exprs value references this name
                var ie_it = ctx.inline_exprs.iterator();
                while (if (prepass) ie_it.next() else null) |ie_entry| {
                    if (ctx.dead_arith.contains(ie_entry.key_ptr.*)) continue; // skip dead exprs
                    const expr = ie_entry.value_ptr.*;
                    if (std.mem.indexOf(u8, expr, dead_name) != null) {
                        // Check it's actually a variable reference (word boundary)
                        // Simple heuristic: name is preceded by space, (, or start; followed by ), +, -, *, /, ,, space, or end
                        const pos = std.mem.indexOf(u8, expr, dead_name).?;
                        const before_ok = pos == 0 or switch (expr[pos - 1]) {
                            ' ', '(', ',', '=', '\t' => true,
                            else => false,
                        };
                        const after_idx = pos + dead_name.len;
                        const after_ok = after_idx >= expr.len or switch (expr[after_idx]) {
                            ' ', ')', ',', '+', '-', '*', '/', '\t', '\n' => true,
                            else => false,
                        };
                        if (before_ok and after_ok) {
                            revive.append(arena, dead_id) catch {};
                            break;
                        }
                    }
                }
            }
            for (revive.items) |rid| {
                _ = ctx.dead_arith.remove(rid);
            }
        }
    }

    // #post-loop-header-use (WGSL port of the MSL #569 / HLSL #570 / GLSL #574
    // hoist): a value the emitter places INSIDE `loop {}` may legally be read at
    // or after the loop's MERGE - SPIR-V only requires def-dominates-use, and a
    // loop header dominates everything downstream, so a header / condition-block
    // value computed inside the emitted loop body is in scope for a LATER loop
    // or for post-loop code in SPIR-V, but not in WGSL's lexical scoping (naga
    // "no definition in scope", graphicsfuzz_015/_059). Two emit shapes land a
    // definition inside the loop: the deferred header replay (the range between
    // the header's last phi and the OpLoopMerge is re-emitted at the top of the
    // loop body) and the body/condition blocks after the OpLoopMerge. Hoist:
    // declare `var v: T;` BEFORE the `loop {` and rewrite the definition's
    // `let v: T = expr;` into `v = expr;` (WGSL vars are function-scoped, so the
    // in-loop assignment and the post-loop read both resolve to it). Sound
    // because the definition executes on every path that reaches a post-loop
    // read (SPIR-V dominance), and the var keeps the most recent execution's
    // value, which is exactly the SSA value at the use. Over-approximates like
    // the C ports: the scan sees SPIR-V refs the emitter may fold away, so some
    // shaders get a redundant declare-then-assign split; semantically identical.
    // LoopMerge instruction index -> hoisted result ids defined inside ITS loop.
    {
        var label_idx = std.AutoHashMap(u32, usize).init(arena);
        defer label_idx.deinit();
        {
            var si: usize = func_idx + 1;
            while (prepass and si < module.instructions.len) : (si += 1) {
                const s = module.instructions[si];
                if (s.op == .FunctionEnd) break;
                if (s.op == .Label and s.words.len > 1) label_idx.put(s.words[1], si) catch {};
            }
        }
        var li: usize = func_idx + 1;
        while (prepass and li < module.instructions.len) : (li += 1) {
            const minst = module.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            // The deferred range starts after the LAST header phi whose `.Phi`
            // handler peek sees this LoopMerge - mirroring the defer trigger in
            // the emit loop below (words.len >= 7 and LoopMerge within the
            // 256-instruction peek window; each qualifying phi overwrites
            // defer_start, so the last one wins). With no qualifying phi nothing
            // is deferred and the in-loop region starts at the LoopMerge itself.
            var last_phi: ?usize = null;
            var pi: usize = li;
            while (prepass and pi > func_idx) : (pi -= 1) {
                const p = module.instructions[pi];
                if (p.op == .Label) break; // start of the header block
                if (p.op != .Phi or p.words.len < 7) continue;
                if (li - pi >= 1 and li - pi < 256) {
                    last_phi = pi;
                    break;
                }
            }
            const region_start = if (last_phi) |lp| lp + 1 else li + 1;
            const merge_idx = label_idx.get(minst.words[1]) orelse continue;
            // Skip the merge block's LEADING OpPhis: a merge phi naming the value
            // is NOT a post-loop read (its incoming copy is made inside the loop,
            // where the value is in scope) - same as the MSL/HLSL/GLSL ports.
            var ci = merge_idx;
            while (prepass and ci < module.instructions.len and (module.instructions[ci].op == .Label or module.instructions[ci].op == .Phi)) : (ci += 1) {}
            var di = region_start;
            while (prepass and di < merge_idx) : (di += 1) {
                const dinst = module.instructions[di];
                if (dinst.op == .Phi or dinst.op == .Label or dinst.op == .Branch or dinst.op == .BranchConditional or dinst.op == .SelectionMerge or dinst.op == .LoopMerge or dinst.op == .FunctionEnd) continue;
                // Ops that emit no `let name: T = ...` statement (name bindings,
                // in-place `var` declarations): hoisting them would emit a
                // nonsense declaration or duplicate one. Their post-loop uses
                // resolve through the names map instead.
                if (dinst.op == .Variable or dinst.op == .AccessChain or dinst.op == .CompositeExtract or dinst.op == .CopyObject) continue;
                const rid = common.resultIdFromOp(dinst.op, dinst.words) orelse continue;
                if (ctx.hoisted_ids.contains(rid)) continue;
                // The def must actually emit a fresh statement under this name:
                // dead/inlined ids are folded into their users (no statement) and
                // a propagated pointer name would collide with the pointer's own
                // declaration.
                if (ctx.dead_arith.contains(rid) or ctx.dead_conditions.contains(rid) or ctx.inline_loads.contains(rid)) continue;
                const nm = names.get(rid) orelse continue;
                if (nm.len == 0 or nm.len > 56) continue;
                var ident = nm[0] == '_' or std.ascii.isAlphabetic(nm[0]);
                if (ident) {
                    for (nm[1..]) |c| {
                        if (!(c == '_' or std.ascii.isAlphanumeric(c))) {
                            ident = false;
                            break;
                        }
                    }
                }
                if (!ident) continue;
                var referenced = false;
                var ri = ci;
                while (prepass and ri < module.instructions.len) : (ri += 1) {
                    const rinst = module.instructions[ri];
                    if (rinst.op == .FunctionEnd) break;
                    var wi: usize = 1;
                    while (prepass and wi < rinst.words.len) : (wi += 1) {
                        if (rinst.words[wi] == rid) {
                            referenced = true;
                            break;
                        }
                    }
                    if (referenced) break;
                }
                if (!referenced) continue;
                ctx.hoisted_ids.put(rid, {}) catch continue;
                const gop = ctx.loop_hoists.getOrPut(li) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(u32).initCapacity(arena, 2) catch continue;
                gop.value_ptr.append(arena, rid) catch {};
            }
        }
    }

    // Emit instructions
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];

        // #post-loop-header-use: the previous walk iteration may have emitted
        // the definition of a hoisted loop value - rewrite its buffered
        // declaration into an assignment to the var declared above the loop,
        // then commit. Doing this HERE (rather than after the switch below)
        // survives the many `continue` arms: the pending buffer holds exactly
        // what was emitted since the last flush.
        try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);

        // Region mode stop conditions. (1) the switch's merge Label at region
        // top level: the case is done. (2) a TOP-LEVEL OpBranch to the switch
        // merge: the implicit case end in WGSL (cases do not fall through),
        // emitted as nothing. A NON-top-level exit to the switch merge is a
        // break the walker cannot spell (no labeled break in WGSL) -- fail
        // loud rather than emit nothing (the silent-truncation class).
        if (range) |r| {
            if (r.stop_label) |sl| {
                var cur_block_label: u32 = 0;
                {
                    var li2: usize = i;
                    while (li2 > 0) : (li2 -= 1) {
                        if (module.instructions[li2].op == .Label and module.instructions[li2].words.len > 1) {
                            cur_block_label = module.instructions[li2].words[1];
                            break;
                        }
                    }
                }
                // words[2] (the TRUE target) must be checked too -- a merge-flag
                // BranchConditional (`if (flag) goto switch-merge else ...`)
                // exits through words[2]; missing it dropped the break and the
                // phi assignment (review finding 1b).
                const branch_to_sl = (inst.op == .Branch or inst.op == .BranchConditional) and inst.words.len > 1 and
                    (inst.words[1] == sl or
                        (inst.op == .BranchConditional and ((inst.words.len > 3 and inst.words[3] == sl) or
                            (inst.words.len > 2 and inst.words[2] == sl))));
                const top_level = if_depth == 0 and loop_stack.items.len == 0;
                if (inst.op == .Label and inst.words.len > 1 and inst.words[1] == sl and top_level) break;
                if (branch_to_sl) {
                    if (top_level) {
                        if (inst.op == .Branch) {
                            // The implicit case end bypasses the .Branch sel-phi
                            // update site, so a switch-merge phi with THIS pred
                            // would keep its init: emit the assignments before
                            // the implicit break (review finding 1b).
                            //
                            // #region-stop-hoist-flush: the assignments must go
                            // to the REAL writer. `w` buffers into the hoist
                            // pending buffer, which is committed only by
                            // hoistSweepAndFlush -- and the `break` below exits
                            // the emit loop with no further flush, so writing
                            // through `w` here silently DROPPED every
                            // assignment on this edge (the phi kept its init:
                            // naga-invalid when the init was mis-scoped,
                            // silently-wrong otherwise). Same shape as the
                            // #wgsl-region-continue edge: flush, then write
                            // past the pending buffer.
                            try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);
                            var spi_x = ctx.sel_phis.iterator();
                            while (spi_x.next()) |ent| {
                                for (ent.value_ptr.*.items) |sp| {
                                    if (sp.pred_label != cur_block_label) continue;
                                    const rn_x = names.get(sp.result_id) orelse continue;
                                    const vn_x = names.get(sp.value_id) orelse continue;
                                    try writeInd(w_out, indent);
                                    try w_out.print("{s} = {s};\n", .{ rn_x, vn_x });
                                }
                            }
                            break;
                        }
                        // A top-level BranchConditional opens a construct the
                        // walker handles natively; fall through.
                    } else {
                        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "a construct inside a switch-case region branches to the switch merge; WGSL cannot spell that break without a flag variable", .{}) catch null;
                        return error.UnsupportedRegionExit;
                    }
                }
            }
            // #wgsl-region-loop-break: a branch to the ENCLOSING loop's merge
            // from inside a switch-case region is a break that must exit the
            // LOOP, but WGSL binds `break` to the innermost switch or loop --
            // inside the case it exits the switch, not the loop, and WGSL has
            // no labeled break. The walker previously DROPPED the edge and
            // fell through into the next block in the instruction stream
            // (leaking a different arm's body into this case, then running
            // the loop tail on the break path: valid WGSL, wrong control
            // flow; both the OpBranch and the BranchConditional-arm forms).
            // spirv-val keeps the deeper shape out (a branch from inside the
            // region's own loop "exits the loop ... not via a structured
            // exit"), so this edge only arises at region top level, plain or
            // under selections. Refuse loud rather than mis-bind; the
            // flag-variable rewrite the message names is the manual
            // workaround. (`continue`, by contrast, binds to the loop through
            // the switch, which is why #wgsl-region-continue can spell its
            // twin.)
            if (r.loop_merge) |om| {
                const branch_to_om = (inst.op == .Branch or inst.op == .BranchConditional) and inst.words.len > 1 and
                    (inst.words[1] == om or
                        (inst.op == .BranchConditional and ((inst.words.len > 3 and inst.words[3] == om) or
                            (inst.words.len > 2 and inst.words[2] == om))));
                if (branch_to_om) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "a construct inside a switch-case region branches to the enclosing loop's merge (a break out of the loop taken from inside the switch); WGSL binds break to the switch there and has no labeled break, so it cannot be spelled without a flag variable", .{}) catch null;
                    return error.UnsupportedRegionExit;
                }
            }
        }

        // If deferring loop header instructions, skip them for now
        // They will be emitted inside the loop body when LoopMerge is encountered
        if (defer_active and inst.op != .LoopMerge and inst.op != .Phi) {
            continue;
        }

        // Skip dead condition bindings that were inlined into BranchConditional
        if (inst.words.len > 2 and ctx.dead_conditions.contains(inst.words[2])) {
            continue;
        }

        // Skip dead arithmetic bindings (user also inlined)
        if (inst.words.len > 2 and ctx.dead_arith.contains(inst.words[2])) {
            if (ctx.def_op.get(inst.words[2])) |def_op_val| {
                if (def_op_val == inst.op) continue;
            }
        }

        switch (inst.op) {
            .FunctionEnd => {
                while (if_depth > 0) : (if_depth -= 1) {
                    indent -= 1;
                    try writeInd(w, indent);
                    try w.writeAll("}");
                    try w.writeAll("\n");
                }
                // #post-loop-header-use: the final instruction may itself be a
                // hoisted definition - rewrite + commit before leaving.
                try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);
                return;
            },
            .SelectionMerge => {
                if (inst.words.len > 1) {
                    pending_merge = inst.words[1];
                    // Pre-declare selection phi variables before the if/else block
                    if (ctx.sel_phis.count() > 0) {
                        if (ctx.sel_phis.get(pending_merge.?)) |phi_list| {
                            // The `var x = <init>` declaration doubles as the assignment
                            // on the edge that BYPASSES the arms (the conditional's false
                            // target is the merge block). That edge leaves the SELECTION
                            // HEADER — the block this OpSelectionMerge sits in — so the
                            // initializer must be the phi incoming whose predecessor IS
                            // the header block. SPIR-V does NOT fix incoming order, so
                            // the old "first incoming's predecessor" heuristic picked the
                            // TAKEN arm's value whenever it was listed first (the wintty
                            // cursor_sweep shape): the arm value failed the defined-before
                            // test below and the emitter silently fell back to a zero-init
                            // `var x: T;` — dropping the not-taken incoming entirely. The
                            // bypass edge then read a type zero instead of the pre-if
                            // value (naga-valid, whole-frame black: zioshade-8h7).
                            var header_label: ?u32 = null;
                            {
                                var hp: usize = i;
                                while (hp > 0) : (hp -= 1) {
                                    const hinst = module.instructions[hp];
                                    if (hinst.op == .Label and hinst.words.len > 1) {
                                        header_label = hinst.words[1];
                                        break;
                                    }
                                }
                            }
                            var init_pred: ?u32 = null;
                            if (header_label != null) {
                                for (phi_list.items) |sp| {
                                    if (sp.pred_label == header_label.?) {
                                        init_pred = header_label;
                                        break;
                                    }
                                }
                            }
                            // if/else where BOTH merge predecessors are arms (no bypass
                            // edge): every edge into the merge assigns at its branch, so
                            // the declaration's initializer is never read. Keep the legacy
                            // first-incoming predecessor so the var is still declared.
                            if (init_pred == null) {
                                const first_phi_result = phi_list.items[0].result_id;
                                const phi_inst = getDef(module, first_phi_result);
                                init_pred = if (phi_inst != null and phi_inst.?.words.len >= 5) phi_inst.?.words[4] else null;
                            }
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
                                                // Loads from variables declared before the if-else are
                                                // safe ONLY when the LOAD ITSELF precedes the
                                                // SelectionMerge: a load emitted inside an arm (or a
                                                // switch-case region) binds its `let` there, so the
                                                // name is not in scope at the pre-declaration site
                                                // (naga "no definition in scope"; region_stop_phi_flush).
                                                if (sp.value_id < module.id_defs.len) {
                                                    if (module.id_defs[sp.value_id]) |vidx| {
                                                        if (vidx < i) use_init = true;
                                                    }
                                                }
                                            } else {
                                                // Check if the value's definition index is before this SelectionMerge.
                                                // Use the index-backed id_defs map: the old text scan compared
                                                // words[2] against the value id for EVERY instruction, but words[2]
                                                // is a result id only for value-producing ops; a non-result
                                                // instruction whose words[2] is data (an OpName string word) can
                                                // numerically alias the value id. tint names a transfer-function
                                                // constant "B" (string word 66), which aliased an arm-local
                                                // VectorShuffle's id: the then-arm value passed as an in-scope
                                                // initializer and the emitted `var phi = <arm value>;` referenced
                                                // a name declared only inside the branch (naga: undeclared
                                                // identifier at exit 0). (#wgsl-cts)
                                                if (sp.value_id < module.id_defs.len) {
                                                    if (module.id_defs[sp.value_id]) |vidx| {
                                                        if (vidx < i) use_init = true;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if (use_init and init_val_name != null) {
                                        try writeInd(w, indent);
                                        if (!ctx.declared_merge_phis.contains(sp.result_id)) {
                                            try w.print("var {s}: {s} = {s};\n", .{ phi_result.?, phi_type, init_val_name.? });
                                        }
                                    } else {
                                        try writeInd(w, indent);
                                        try w.print("var {s}: {s};\n", .{ phi_result.?, phi_type });
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
                        // #wgsl-loop-in-switch-case: any OpLoopMerge between OpSwitch and
                        // the switch merge sits in a case body. The whole region is
                        // consumed by this handler and replayed via emitSimpleInstruction,
                        // which cannot construct loops, so such a loop would be silently
                        // DROPPED. Honest-error instead of miscompiling. (Full loop-in-case
                        // emission is a tracked follow-up.)
                        //
                        // #wgsl-nested-switch-in-switch-case: an OpSwitch between this
                        // OpSwitch and its merge sits in a case body. The case-body replay
                        // does `if (dinst.op == .Switch) break;` (default + case arms), so
                        // it stops at the inner OpSwitch and silently DROPS it plus every
                        // instruction after it in the case body (nested_switch: outv stayed
                        // 0). Honest-error instead of miscompiling.
                        {
                            var li: usize = i + 1;
                            while (li < module.instructions.len) : (li += 1) {
                                const linst = module.instructions[li];
                                if (linst.op == .Label and linst.words.len > 1 and linst.words[1] == merge_label.?) break;
                                // LoopMerge no longer refuses here: #wgsl-region-mode
                                // dispatches a case-body branch to a loop header
                                // into the real walker (sharing the WalkCtx).
                                // Shapes the dispatch cannot reach still fail
                                // loud at the replay's Phi/arm guards.
                                if (linst.op == .Switch) return recordUnsupportedNestedSwitchInSwitchCase();
                            }
                        }
                        // All OpSwitch target labels + default: branches to
                        // these from inside a case are fallthrough (handled by
                        // the case-arm body duplication) and must not trip the
                        // truncation guard below.
                        var switch_targets = std.ArrayListUnmanaged(u32).empty;
                        defer switch_targets.deinit(arena);
                        switch_targets.append(arena, default_label) catch {};
                        {
                            var wi: usize = 3;
                            while (wi + 1 < inst.words.len) : (wi += 2) {
                                switch_targets.append(arena, inst.words[wi + 1]) catch {};
                            }
                        }
                        try writeInd(w, indent);
                        try w.print("switch {s} {{\n", .{selector});
                        const case_ind = indent + 1;
                        const body_ind = indent + 2;
                        // Emit default case (WGSL requires exactly one default)
                        if (default_label != merge_label.?) {
                            try writeInd(w, case_ind);
                            try w.writeAll("default: {\n");
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
                                        if (dinst.op == .Branch) {
                                            // implicit_break: reaching the switch's merge is
                                            // the ordinary end of the case and WGSL cases do not
                                            // fall through, so neither merge nor fallthrough
                                            // targets emit anything here; unknown targets refuse
                                            // (UnsupportedSwitchCaseExit). NOTE: the default arm
                                            // has no fallthrough chain duplication, so a default
                                            // body branching into a later case still silently
                                            // drops that fallthrough (pre-existing; the region
                                            // walker replaces these walks).
                                            // #wgsl-region-mode: a branch to a LOOP HEADER hands
                                            // the rest of the case to the real walker -- the
                                            // case-body replay cannot construct loops. The region
                                            // SHARES this WalkCtx (no preamble re-runs) and owns
                                            // everything through the case's terminating branch to
                                            // the switch merge, so the arm walk simply ends here.
                                            blk_region: {
                                                const btgt = if (dinst.words.len > 1) dinst.words[1] else 0;
                                                const lhdr = labelIsLoopHeader(module, btgt) orelse break :blk_region;
                                                try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);
                                                const region_depth: u32 = if (range) |rr| rr.depth else 0;
                                                try emitBody(module, names, decorations, func_idx, w_out, alloc, arena, inout_return, skip_store_target, skip_store_targets, wrapped_uniform_arrays, wrapped_members, matrix_outputs, atomic_vars, atomic_fields, nonuniform_gated, early_return, subpass_fragcoord_name, ctx, .{
                                                    .start_idx = lhdr + 1,
                                                    .stop_label = merge_label,
                                                    .indent = body_ind,
                                                    .loop_continue = if (in_loop) loop_continue_label else null,
                                                    .loop_merge = if (in_loop) loop_merge_label else null,
                                                    .depth = region_depth + 1,
                                                });
                                                break;
                                            }
                                            try emitSwitchArmTerminator(module, si, merge_label.?, true, switch_targets.items, if (in_loop) loop_continue_label else null, w, body_ind);
                                            break;
                                        }
                                        if (dinst.op == .BranchConditional) {
                                            // #478 F4: emit a nested if/else within the case body (was dropped).
                                            const bcond = names.get(dinst.words[1]) orelse "c";
                                            const btrue = dinst.words[2];
                                            const bfalse = if (dinst.words.len > 3) dinst.words[3] else null;
                                            var merge_lbl: u32 = 0;
                                            if (si > 0 and module.instructions[si - 1].op == .SelectionMerge and module.instructions[si - 1].words.len > 1)
                                                merge_lbl = module.instructions[si - 1].words[1];
                                            try writeInd(w, body_ind);
                                            try w.print("if {s} {{\n", .{bcond});
                                            // Emit true arm
                                            {
                                                var ti = si + 1;
                                                while (ti < module.instructions.len) : (ti += 1) {
                                                    if (module.instructions[ti].op == .Label and module.instructions[ti].words.len > 1 and module.instructions[ti].words[1] == btrue) {
                                                        ti += 1;
                                                        while (ti < module.instructions.len) : (ti += 1) {
                                                            const tinst = module.instructions[ti];
                                                            if (tinst.op == .Label or tinst.op == .Branch or tinst.op == .BranchConditional) break;
                                                            try emitSimpleInstruction(module, names, &ctx.inline_exprs, tinst, w, alloc, arena, body_ind + 1, wrapped_members, matrix_outputs, nonuniform_gated);
                                                        }
                                                        // The arm's terminator was skipped by the loop above. When it branches
                                                        // to the SWITCH's merge it is a `break` out of the switch, and dropping
                                                        // it let the statements after the `if` run on a path that should have
                                                        // exited (graphicsfuzz_081 emitted `if v36 { }`). MSL emits
                                                        // `if (v38) { break; }` for the same shader.
                                                        try emitSwitchArmTerminator(module, ti, merge_label.?, false, &.{merge_lbl}, if (in_loop) loop_continue_label else null, w, body_ind + 1);
                                                        break;
                                                    }
                                                }
                                            }
                                            if (bfalse) |bf| {
                                                if (bf != merge_lbl) {
                                                    try writeInd(w, body_ind);
                                                    try w.writeAll("} else {\n");
                                                    var fi = si + 1;
                                                    while (fi < module.instructions.len) : (fi += 1) {
                                                        if (module.instructions[fi].op == .Label and module.instructions[fi].words.len > 1 and module.instructions[fi].words[1] == bf) {
                                                            fi += 1;
                                                            while (fi < module.instructions.len) : (fi += 1) {
                                                                const finst = module.instructions[fi];
                                                                if (finst.op == .Label or finst.op == .Branch or finst.op == .BranchConditional) break;
                                                                try emitSimpleInstruction(module, names, &ctx.inline_exprs, finst, w, alloc, arena, body_ind + 1, wrapped_members, matrix_outputs, nonuniform_gated);
                                                            }
                                                            try emitSwitchArmTerminator(module, fi, merge_label.?, false, &.{merge_lbl}, if (in_loop) loop_continue_label else null, w, body_ind + 1);
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            try writeInd(w, body_ind);
                                            try w.writeAll("}\n");
                                            // Advance si past the if/else blocks to the merge.
                                            if (merge_lbl != 0) {
                                                var mi = si + 1;
                                                while (mi < module.instructions.len) : (mi += 1) {
                                                    if (module.instructions[mi].op == .Label and module.instructions[mi].words.len > 1 and module.instructions[mi].words[1] == merge_lbl) {
                                                        si = mi;
                                                        break;
                                                    }
                                                }
                                            }
                                            continue;
                                        }
                                        if (dinst.op == .Switch) break;
                                        try emitSimpleInstruction(module, names, &ctx.inline_exprs, dinst, w, alloc, arena, body_ind, wrapped_members, matrix_outputs, nonuniform_gated);
                                    }
                                    break;
                                }
                            }
                            // #477: sel_phi update for this case's branch-to-merge
                            // (the case body's OpBranch is dropped by the loop above, so
                            // the main .Branch sel_phi update never fires from a case).
                            if (ctx.sel_phis.get(merge_label.?)) |phi_list| {
                                for (phi_list.items) |sp| {
                                    if (sp.pred_label == default_label) {
                                        const rn = names.get(sp.result_id) orelse continue;
                                        const vn = names.get(sp.value_id) orelse continue;
                                        try writeInd(w, body_ind);
                                        try w.print("{s} = {s};\n", .{ rn, vn });
                                    }
                                }
                            }
                            try writeInd(w, case_ind);
                            try w.writeAll("}\n");
                        } else {
                            // Default targets merge — emit empty default (WGSL requires it)
                            try writeInd(w, case_ind);
                            try w.writeAll("default: {\n");
                            try writeInd(w, case_ind);
                            try w.writeAll("}\n");
                        }
                        // Emit case targets
                        var wi: usize = 3;
                        while (wi + 1 < inst.words.len) : (wi += 2) {
                            const case_val = inst.words[wi];
                            const target_label = inst.words[wi + 1];
                            if (target_label == merge_label.?) continue;
                            try writeInd(w, case_ind);
                            try w.print("case {d}: {{\n", .{switchCaseLiteral(module, inst.words[1], case_val)});
                            // #switch-fallthrough: WGSL removed `fallthrough` from the spec, so a
                            // SPIR-V fallthrough chain is rendered by DUPLICATING each subsequent
                            // case's body into this one (cases share the accumulated variable, so the
                            // running sum matches spirv-cross). The chain follows the case body's
                            // OpBranch target only when it is another case label; terminal cases
                            // (OpBranch to the merge) and non-fallthrough cases emit exactly one
                            // block — byte-identical to before.
                            var chain_label = target_label;
                            var chain_guard: usize = 0;
                            while (chain_guard < inst.words.len) : (chain_guard += 1) {
                                var term_target: ?u32 = null;
                                var si: usize = i + 1;
                                while (si < module.instructions.len) : (si += 1) {
                                    const sinst = module.instructions[si];
                                    if (sinst.op == .Label and sinst.words.len > 1 and sinst.words[1] == chain_label) {
                                        si += 1;
                                        while (si < module.instructions.len) : (si += 1) {
                                            const dinst = module.instructions[si];
                                            if (dinst.op == .Label) break;
                                            if (dinst.op == .Branch) {
                                                if (dinst.words.len > 1) term_target = dinst.words[1];
                                                // #wgsl-region-mode: a branch to a LOOP HEADER hands
                                                // the rest of the case to the real walker -- the
                                                // case-body replay cannot construct loops. The region
                                                // SHARES this WalkCtx (no preamble re-runs) and owns
                                                // everything through the case's terminating branch to
                                                // the switch merge, so the arm walk simply ends here.
                                                blk_region: {
                                                    const btgt = if (dinst.words.len > 1) dinst.words[1] else 0;
                                                    const lhdr = labelIsLoopHeader(module, btgt) orelse break :blk_region;
                                                    try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);
                                                    const region_depth: u32 = if (range) |rr| rr.depth else 0;
                                                    try emitBody(module, names, decorations, func_idx, w_out, alloc, arena, inout_return, skip_store_target, skip_store_targets, wrapped_uniform_arrays, wrapped_members, matrix_outputs, atomic_vars, atomic_fields, nonuniform_gated, early_return, subpass_fragcoord_name, ctx, .{
                                                        .start_idx = lhdr + 1,
                                                        .stop_label = merge_label,
                                                        .indent = body_ind,
                                                        .loop_continue = if (in_loop) loop_continue_label else null,
                                                        .loop_merge = if (in_loop) loop_merge_label else null,
                                                        .depth = region_depth + 1,
                                                    });
                                                    break;
                                                }
                                                try emitSwitchArmTerminator(module, si, merge_label.?, true, switch_targets.items, if (in_loop) loop_continue_label else null, w, body_ind);
                                                break;
                                            }
                                            if (dinst.op == .BranchConditional) {
                                                // #478 F4: emit a nested if/else within the case body (was dropped).
                                                const bcond = names.get(dinst.words[1]) orelse "c";
                                                const btrue = dinst.words[2];
                                                const bfalse = if (dinst.words.len > 3) dinst.words[3] else null;
                                                var merge_lbl: u32 = 0;
                                                if (si > 0 and module.instructions[si - 1].op == .SelectionMerge and module.instructions[si - 1].words.len > 1)
                                                    merge_lbl = module.instructions[si - 1].words[1];
                                                try writeInd(w, body_ind);
                                                try w.print("if {s} {{\n", .{bcond});
                                                // Emit true arm
                                                {
                                                    var ti = si + 1;
                                                    while (ti < module.instructions.len) : (ti += 1) {
                                                        if (module.instructions[ti].op == .Label and module.instructions[ti].words.len > 1 and module.instructions[ti].words[1] == btrue) {
                                                            ti += 1;
                                                            while (ti < module.instructions.len) : (ti += 1) {
                                                                const tinst = module.instructions[ti];
                                                                if (tinst.op == .Label or tinst.op == .Branch or tinst.op == .BranchConditional) break;
                                                                try emitSimpleInstruction(module, names, &ctx.inline_exprs, tinst, w, alloc, arena, body_ind + 1, wrapped_members, matrix_outputs, nonuniform_gated);
                                                            }
                                                            try emitSwitchArmTerminator(module, ti, merge_label.?, false, &.{merge_lbl}, if (in_loop) loop_continue_label else null, w, body_ind + 1);
                                                            break;
                                                        }
                                                    }
                                                }
                                                if (bfalse) |bf| {
                                                    if (bf != merge_lbl) {
                                                        try writeInd(w, body_ind);
                                                        try w.writeAll("} else {\n");
                                                        var fi = si + 1;
                                                        while (fi < module.instructions.len) : (fi += 1) {
                                                            if (module.instructions[fi].op == .Label and module.instructions[fi].words.len > 1 and module.instructions[fi].words[1] == bf) {
                                                                fi += 1;
                                                                while (fi < module.instructions.len) : (fi += 1) {
                                                                    const finst = module.instructions[fi];
                                                                    if (finst.op == .Label or finst.op == .Branch or finst.op == .BranchConditional) break;
                                                                    try emitSimpleInstruction(module, names, &ctx.inline_exprs, finst, w, alloc, arena, body_ind + 1, wrapped_members, matrix_outputs, nonuniform_gated);
                                                                }
                                                                try emitSwitchArmTerminator(module, fi, merge_label.?, false, &.{merge_lbl}, if (in_loop) loop_continue_label else null, w, body_ind + 1);
                                                                break;
                                                            }
                                                        }
                                                    }
                                                }
                                                try writeInd(w, body_ind);
                                                try w.writeAll("}\n");
                                                // Advance si past the if/else blocks to the merge.
                                                if (merge_lbl != 0) {
                                                    var mi = si + 1;
                                                    while (mi < module.instructions.len) : (mi += 1) {
                                                        if (module.instructions[mi].op == .Label and module.instructions[mi].words.len > 1 and module.instructions[mi].words[1] == merge_lbl) {
                                                            si = mi;
                                                            break;
                                                        }
                                                    }
                                                }
                                                continue;
                                            }
                                            if (dinst.op == .Switch) break;
                                            try emitSimpleInstruction(module, names, &ctx.inline_exprs, dinst, w, alloc, arena, body_ind, wrapped_members, matrix_outputs, nonuniform_gated);
                                        }
                                        break;
                                    }
                                }
                                // Follow the fallthrough chain only if this block OpBranched to
                                // another CASE target (not the merge, not an external label).
                                const follow = blk: {
                                    if (term_target) |tt| {
                                        if (tt != merge_label.? and isSwitchCaseTarget(inst.words, tt)) break :blk tt;
                                    }
                                    break :blk @as(?u32, null);
                                };
                                if (follow) |tt| {
                                    chain_label = tt;
                                    continue;
                                }
                                break;
                            }
                            // #477: sel_phi update for this case's branch-to-merge.
                            if (ctx.sel_phis.get(merge_label.?)) |phi_list| {
                                for (phi_list.items) |sp| {
                                    if (sp.pred_label == target_label) {
                                        const rn = names.get(sp.result_id) orelse continue;
                                        const vn = names.get(sp.value_id) orelse continue;
                                        try writeInd(w, body_ind);
                                        try w.print("{s} = {s};\n", .{ rn, vn });
                                    }
                                }
                            }
                            try writeInd(w, case_ind);
                            try w.writeAll("}\n");
                        }
                        try writeInd(w, indent);
                        try w.writeAll("}\n");
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
                    // #loop-continue-deadincr (WGSL): wrap the continue-block content + back-edge
                    // phi updates in `continuing {}` so a body `continue` advances the counter
                    // (WGSL `continue` in a loop jumps to the continuing block; without it the
                    // increment sat at the body bottom where `continue` skipped it -> infinite
                    // loop, same class as the MSL/GLSL/HLSL bug). ONLY when the continue block
                    // ends in a plain OpBranch to the header — a do-while's continue block ends
                    // in a BranchConditional back-edge, which the .Branch handler below does not
                    // close on (so `continuing {}` would be left open and naga would reject it),
                    // and ONLY when it has content or header phis (an empty continuing block is
                    // invalid WGSL).
                    var emit_continuing = false;
                    scan_cont: {
                        var ci2: usize = i + 1;
                        while (ci2 < module.instructions.len) : (ci2 += 1) {
                            const cin = module.instructions[ci2];
                            if (cin.op == .Label and cin.words.len > 1 and cin.words[1] == cont) break;
                            if (cin.op == .FunctionEnd) break :scan_cont;
                        }
                        var has_content = (phi_start < phi_end);
                        var ends_in_branch = false;
                        ci2 += 1; // past the continue label
                        while (ci2 < module.instructions.len) : (ci2 += 1) {
                            const cin = module.instructions[ci2];
                            if (cin.op == .Branch) {
                                ends_in_branch = true;
                                break;
                            }
                            if (cin.op == .BranchConditional or cin.op == .FunctionEnd) break;
                            switch (cin.op) {
                                .Label, .Phi, .LoopMerge, .SelectionMerge => {},
                                else => {
                                    has_content = true;
                                },
                            }
                        }
                        emit_continuing = has_content and ends_in_branch;
                    }
                    try loop_stack.append(arena, .{ .merge = merge, .cont = cont, .header = header, .phi_start = phi_start, .phi_end = phi_end, .emit_continuing = emit_continuing, .continuing_open = false });
                    // #post-loop-header-use: declare the loop's hoisted values
                    // ABOVE the `loop {`. Their definition sites (the deferred
                    // header replay below or a body block) are rewritten from
                    // `let v: T = e;` to `v = e;` by the pending-writer hoist
                    // sweep, so this pre-declared `var` is what every in-loop
                    // and post-loop read resolves to.
                    if (ctx.loop_hoists.get(i)) |hl| {
                        for (hl.items) |rid| {
                            const hname = names.get(rid) orelse continue;
                            const hdef = common.getDef(module, rid) orelse continue;
                            if (hdef.words.len < 2) continue;
                            const hty = wgslType(module, hdef.words[1], names, arena) catch continue;
                            // Written to the REAL writer, bypassing the pending
                            // buffer: the sweep would otherwise rewrite/drop this
                            // very declaration (it matches the `var name: T;`
                            // shape it exists to eliminate at the DEF site).
                            try writeInd(w_out, indent);
                            try w_out.print("var {s}: {s};\n", .{ hname, hty });
                        }
                    }
                    // #wgsl-loop-merge-phi: declare the merge block's phis before the
                    // loop. The sel-phi machinery only materializes under a
                    // SelectionMerge, and a loop exit has none -- so a phi at the
                    // loop's merge (e.g. the "did we break" flag read after the
                    // loop) was never declared and post-loop reads referenced an
                    // unbound identifier (naga "no definition in scope"; every pred
                    // of a loop merge is INSIDE the loop, so the init is a type zero
                    // -- each path into the merge assigns first: the header/body test
                    // exits below, the mid-loop break via the .Branch sel-phi updates).

                    if (ctx.sel_phis.get(merge)) |phi_list| {
                        if (phi_list.items.len > 0) {
                            var seen_lmp = std.AutoHashMap(u32, void).init(arena);
                            for (phi_list.items) |sp| {
                                if (seen_lmp.contains(sp.result_id)) continue;
                                // A merge block claimed by BOTH a SelectionMerge and
                                // this loop (canonical `if (c) { while ... }` with
                                // nothing after the loop in the arm: the selection's
                                // merge == the loop's merge) was declared TWICE --
                                // the inner var shadows, the exit assignments write
                                // the shadow, the post-if read sees the outer init.
                                // The SelectionMerge declaration is in scope for the
                                // exit assignments, so suppress here.
                                if (ctx.declared_merge_phis.contains(sp.result_id)) continue;
                                seen_lmp.put(sp.result_id, {}) catch {};
                                var phi_result = names.get(sp.result_id);
                                if (phi_result == null) {
                                    var nbuf: [64]u8 = undefined;
                                    const dname = std.fmt.bufPrint(&nbuf, "v{d}", .{sp.result_id}) catch "phi";
                                    const dcopy = try alloc.dupe(u8, dname);
                                    try names.put(sp.result_id, dcopy);
                                    phi_result = dcopy;
                                }
                                const pdef = getDef(module, sp.result_id) orelse continue;
                                if (pdef.words.len < 2) continue;
                                const pty = wgslType(module, pdef.words[1], names, arena) catch continue;
                                const pzero = zeroLiteralOfType(module, pdef.words[1], names, alloc) orelse continue;
                                // REAL writer, bypassing the pending buffer (same as the
                                // hoist decls above -- the sweep would rewrite this `var`).
                                try writeInd(w_out, indent);
                                try w_out.print("var {s}: {s} = {s};\n", .{ phi_result.?, pty, pzero });
                                alloc.free(pzero);
                                ctx.declared_merge_phis.put(sp.result_id, {}) catch {};
                            }
                        }
                    }
                    try writeInd(w, indent);
                    try w.writeAll("loop {\n");
                    indent += 1;
                    // Replay deferred loop header instructions inside the loop
                    if (defer_active and defer_start != null) {
                        defer_active = false;
                        var di: usize = defer_start.?;
                        while (di < i) : (di += 1) {
                            const dinst = module.instructions[di];
                            if (dinst.op == .Nop or dinst.op == .Label) continue;
                            // Skip dead conditions that were inlined
                            if (dinst.words.len > 2 and ctx.dead_conditions.contains(dinst.words[2])) continue;
                            // Emit common instruction types inline
                            switch (dinst.op) {
                                .BranchConditional, .Branch, .SelectionMerge, .LoopMerge, .Phi, .FunctionEnd => {},
                                else => {
                                    try emitSimpleInstruction(module, names, &ctx.inline_exprs, dinst, w, alloc, arena, indent, wrapped_members, matrix_outputs, nonuniform_gated);
                                },
                            }
                        }
                        defer_start = null;
                        // The replay renames header extracts AT REPLAY TIME
                        // (expr-ification, no let binding); cached expressions
                        // over the old names go stale. Re-sweep. (Found via
                        // the #wgsl-region-mode work on graphicsfuzz_052: the
                        // cached `v17[v33]` vs the live `v17[v32.y]`; the
                        // class is not region-specific -- any loop-header
                        // extract feeding a cached chain hits it.)
                        try fixStaleExtractNames(names, ctx, alloc, arena);
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
                        var spi = ctx.sel_phis.iterator();
                        while (spi.next()) |entry| {
                            for (entry.value_ptr.*.items) |sp| {
                                if (sp.result_id == phi_result_id or ctx.declared_merge_phis.contains(phi_result_id)) {
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
                    var lm_cont: ?u32 = null; // #selfloop: the LoopMerge's continue label
                    {
                        // #phi-peek-window: see the ctx.sel_phis scan. Same widening, same
                        // Label stop; must agree with that scan or a phi classified as a
                        // loop phi here but as a selection phi there loses its declaration.
                        var pk = i + 1;
                        while (pk < @min(i + 256, module.instructions.len)) : (pk += 1) {
                            if (module.instructions[pk].op == .LoopMerge) {
                                lm_follows = true;
                                if (module.instructions[pk].words.len >= 3) lm_cont = module.instructions[pk].words[2];
                                break;
                            }
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
                    // #selfloop: a self-loop's continue target IS its header (cont ==
                    // header), so the back-edge predecessor's Label sits in the SAME block
                    // as this phi (before it) -- the index heuristic above then misreads the
                    // back-edge incoming as the init (`var = <not-yet-defined increment>`
                    // -> nana "no definition in scope" + the counter never advances). The
                    // header Label is the nearest Label before this phi; if it equals the
                    // LoopMerge's continue target, override: the pair whose predecessor IS
                    // the header carries the back-edge (update) value; the other (preheader)
                    // carries the init. (Normal loops keep the index heuristic unchanged.)
                    if (lm_follows and lm_cont != null) blk: {
                        var hdr_lbl: u32 = 0;
                        var hp: usize = i;
                        while (hp > 0) : (hp -= 1) {
                            if (module.instructions[hp].op == .Label and module.instructions[hp].words.len > 1) {
                                hdr_lbl = module.instructions[hp].words[1];
                                break;
                            }
                        }
                        if (hdr_lbl == 0 or lm_cont.? != hdr_lbl) break :blk;
                        var pp2: usize = 3;
                        while (pp2 + 1 < inst.words.len) : (pp2 += 2) {
                            const val_id = inst.words[pp2];
                            const lbl_id = inst.words[pp2 + 1];
                            if (lbl_id == hdr_lbl) update_value_id = val_id else init_value_id = val_id;
                        }
                    }
                    if (!already_declared) {
                        const phi_type = try wgslType(module, inst.words[1], names, arena);
                        const init_val = names.get(init_value_id) orelse "0";
                        try writeInd(w, indent);
                        try w.print("var {s}: {s} = {s};\n", .{ phi_result.?, phi_type, init_val });
                    }
                    if (lm_follows and !phi_group_open) {
                        // First loop-header phi of this loop: open the group once so
                        // ALL of the header's phis are captured (set BEFORE adding).
                        pending_phi_start = phi_updates.items.len;
                        phi_group_open = true;
                    }
                    if (inst.words.len >= 7) {
                        // append (not appendAssumeCapacity): phi_updates accumulates one
                        // entry per loop-header phi across ALL loops in the function, so a
                        // function with more loop-header phis than the initial capacity
                        // (e.g. several loops each carrying multiple variables) would
                        // otherwise overflow and panic — the loop-merge twin of the
                        // selection-merge phi overflow. Grow instead. (#170 no-panic.)
                        try phi_updates.append(arena, .{ .result_id = inst.words[2], .value_id = update_value_id });
                    }
                    // Check if LoopMerge follows. Two scans, so the legacy behavior
                    // is preserved EXACTLY and only new territory gets stricter
                    // bounds: (1) the original 30-instruction window that crosses
                    // Labels (unchanged from before #phi-peek-window), and (2) an
                    // extension to 256 that stops at a Label/SelectionMerge - a
                    // LoopMerge past a Label belongs to a different (nested/later)
                    // loop, and deferring across it would swallow that loop's header
                    // into this one's replay (#phi-peek-window widened the ctx.sel_phis
                    // and lm_follows scans, which already stopped at Labels; the
                    // defer trigger needs the same reach for headers longer than 30
                    // instructions, graphicsfuzz_015 has one at exactly +30).
                    var peek: usize = i + 1;
                    var defer_fired = false;
                    const legacy_end = @min(i + 30, module.instructions.len);
                    while (peek < legacy_end) : (peek += 1) {
                        if (module.instructions[peek].op == .LoopMerge) {
                            defer_fired = true;
                            break;
                        }
                        if (module.instructions[peek].op == .FunctionEnd or module.instructions[peek].op == .SelectionMerge) break;
                    }
                    if (!defer_fired) {
                        // #phi-peek-window extension: only a LoopMerge in the
                        // phi's OWN block may be deferred to. Verified directly
                        // (same enclosing Label), which is exact where window
                        // heuristics are not: a loop header block is exactly
                        // phis + straight-line instructions + LoopMerge, so a
                        // LoopMerge reached across a Label/terminator belongs to
                        // a different (nested/later) loop.
                        peek = @max(peek, legacy_end);
                        const ext_end = @min(i + 256, module.instructions.len);
                        var phi_blk: usize = i;
                        while (phi_blk > 0 and module.instructions[phi_blk].op != .Label) : (phi_blk -= 1) {}
                        while (peek < ext_end) : (peek += 1) {
                            if (module.instructions[peek].op == .LoopMerge) {
                                var lm_blk: usize = peek;
                                while (lm_blk > 0 and module.instructions[lm_blk].op != .Label) : (lm_blk -= 1) {}
                                if (lm_blk == phi_blk) defer_fired = true;
                                break;
                            }
                        }
                    }
                    if (defer_fired) {
                        defer_active = true;
                        defer_start = i + 1;
                    }
                }
            },
            .BranchConditional => {
                if (inst.words.len >= 4) {
                    const condition = names.get(inst.words[1]) orelse "true";
                    const true_label = inst.words[2];
                    const false_label = inst.words[3];
                    // #selfloop: a reversed-polarity self-loop back-edge
                    // (OpBranchConditional %cond %merge %hdr -- true->merge=break,
                    // false->header=continue) is NOT handled by the normal-polarity exit
                    // path below (which is the only place the self-loop phi back-edge
                    // update is emitted); it would silently drop the update -> the counter
                    // never advances -> infinite loop (valid WGSL, naga-accepted = silent-
                    // wrong, a regression vs the pre-override naga-reject). GLSL/MSL
                    // honest-error this; mirror them. Precise: requires cont == header
                    // (self-loop), true->merge (break on true), false->header (continue).
                    // A normal loop has cont != header; a normal-polarity self-loop has
                    // true->header, so neither trips this.
                    if (in_loop and loop_merge_label != null and loop_continue_label != null and
                        loop_header_label != null and
                        loop_continue_label.? == loop_header_label.? and
                        true_label == loop_merge_label.? and
                        false_label == loop_header_label.?)
                    {
                        return error.CrossCompileUnsupported;
                    }
                    // Check if this is a loop exit condition (BranchConditional in loop header)
                    if (in_loop and loop_merge_label != null and false_label == loop_merge_label.? and pending_merge == null) {
                        // Loop condition: if (!cond) { break; }
                        // Try to inline the condition expression for correctness
                        // (cached let values may be stale if they reference phi vars)
                        const inlined = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                        const cond_expr = inlined orelse condition;
                        if (inlined != null) {
                            ctx.dead_conditions.put(inst.words[1], {}) catch {};
                        }
                        // #wgsl-loop-merge-phi: the exit path assigns the merge phis
                        // before breaking (declared above the loop).
                        const lmp_assigns = try loopExitPhiAssignments(module, names, ctx, i, func_idx, loop_merge_label.?, arena, null);
                        try writeInd(w, indent);
                        if (lmp_assigns.len > 0) {
                            try w.print("if (!({s})) {{ {s}break; }}\n", .{ cond_expr, lmp_assigns });
                        } else {
                            try w.print("if (!({s})) {{ break; }}\n", .{cond_expr});
                        }
                        // #selfloop: a self-loop (continue == header) has no `continuing {}`
                        // block (the continue scan finds the header Label BEFORE the
                        // LoopMerge), so the loop-carried phi updates would never emit ->
                        // the counter never advances -> infinite loop. Emit them here, on
                        // the continue path (after the break test), mirroring spirv-cross
                        // and the GLSL emitSelfLoopBodyHeaderGLSL lowering. Gated on the
                        // self-loop shape so normal loops (which use continuing {}) are
                        // unaffected.
                        if (loop_continue_label != null and loop_header_label != null and
                            loop_continue_label.? == loop_header_label.? and loop_stack.items.len > 0)
                        {
                            const cur = &loop_stack.items[loop_stack.items.len - 1];
                            var pi2: usize = cur.phi_start;
                            while (pi2 < cur.phi_end) : (pi2 += 1) {
                                const pu = phi_updates.items[pi2];
                                const rname = names.get(pu.result_id) orelse continue;
                                const vname = names.get(pu.value_id) orelse continue;
                                try writeInd(w, indent);
                                try w.print("{s} = {s};\n", .{ rname, vname });
                            }
                        }
                        // #wrap-backedge: if the other arm targets this loop's
                        // header, the fall-through past the break IS the back edge
                        // and the loop-carried phi updates belong right here -
                        // otherwise they were silently dropped (counter never
                        // advanced).
                        try emitWrapBackedgePhiUpdates(module, names, &phi_updates, &loop_stack, loop_header_label, loop_continue_label, true_label, w, indent);
                    } else if (pending_merge != null) {
                        const merge_label = pending_merge.?;
                        // Check if this is a break/continue inside a loop. The break
                        // target may be the loop merge DIRECTLY (optimized SPIR-V) or
                        // an INDIRECT pure trampoline block that just `OpBranch`es to
                        // the loop merge (glslang `-V`, unoptimized: `if(cond) break;`).
                        // Both must emit `break;` — missing the trampoline form dropped
                        // the branch → an empty `if (cond) { }` = silent-wrong. (#170)
                        //
                        // A target that IS this selection's own merge is never a trampoline,
                        // however much it looks like one. The merge is where the two arms
                        // rejoin; that it goes on to branch to the loop's continue or merge
                        // block is just what the block after an `if` does. Classifying it as
                        // a trampoline inverts the selection: graphicsfuzz_061 emitted
                        // `if (!c) { continue; }` followed by the true arm UNCONDITIONALLY
                        // and then the continue block's own instructions inline, so the
                        // loop's `canwalk` exit test sat after an unconditional `return` and
                        // could never run. The loop had no exit at all -- every iteration
                        // either continued or returned white, and the black path after the
                        // loop was dead. naga puts that test in `continuing { break if ... }`.
                        // The DIRECT forms below stay unguarded: when the selection merge
                        // genuinely IS the loop merge, branching there really is a break.
                        const true_is_break = in_loop and loop_merge_label != null and
                            (true_label == loop_merge_label.? or
                                (true_label != merge_label and isPureBranchTrampoline(module, true_label, loop_merge_label.?)));
                        const false_is_break = in_loop and loop_merge_label != null and
                            (false_label == loop_merge_label.? or
                                (false_label != merge_label and isPureBranchTrampoline(module, false_label, loop_merge_label.?)));
                        // Continue, like break, may be DIRECT (the branch target IS
                        // the loop continue block) or an INDIRECT pure trampoline that
                        // just `OpBranch`es to the continue block (glslang `-V`,
                        // unoptimized: `if(cond) continue;`). Both must emit `continue;`
                        // (with the loop's phi/counter updates first) — missing the
                        // trampoline form dropped the branch → an empty `if (cond) { }`
                        // = silent-wrong (the body ran when it should have skipped). (#170)
                        const true_is_continue = in_loop and loop_continue_label != null and
                            (true_label == loop_continue_label.? or
                                (true_label != merge_label and isPureBranchTrampoline(module, true_label, loop_continue_label.?)));
                        const false_is_continue = in_loop and loop_continue_label != null and
                            (false_label == loop_continue_label.? or
                                (false_label != merge_label and isPureBranchTrampoline(module, false_label, loop_continue_label.?)));
                        if (true_is_break) {
                            // if (cond) { break; }
                            const inlined2 = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                            if (inlined2 != null) ctx.dead_conditions.put(inst.words[1], {}) catch {};
                            // #wgsl-loop-merge-phi: a mid-loop break assigns the
                            // merge phis before breaking (declared above the loop).
                            const lmp_break = if (loop_merge_label) |lml| try loopExitPhiAssignments(module, names, ctx, i, func_idx, lml, arena, if (true_label == lml) null else true_label) else "";
                            try writeInd(w, indent);
                            if (lmp_break.len > 0) {
                                try w.print("if ({s}) {{ {s}break; }}\n", .{ inlined2 orelse condition, lmp_break });
                            } else {
                                try w.print("if ({s}) {{ break; }}\n", .{inlined2 orelse condition});
                            }
                            // #wrap-backedge: when the OTHER arm targets this loop's
                            // header, the fall-through past the break IS the back edge
                            // (a continue block ending in a BranchConditional); the
                            // loop-carried phi updates belong right here. See the twin
                            // comment in the loop-condition path above.
                            try emitWrapBackedgePhiUpdates(module, names, &phi_updates, &loop_stack, loop_header_label, loop_continue_label, false_label, w, indent);
                            pending_merge = null;
                            i = skipBreakArm(module, i, true_label, loop_merge_label.?);
                        } else if (false_is_break) {
                            // if (!(cond)) { break; }
                            const inlined3 = inlineConditionExpr(module, names, inst.words[1], arena, 0);
                            if (inlined3 != null) ctx.dead_conditions.put(inst.words[1], {}) catch {};
                            try writeInd(w, indent);
                            const lmp_assigns2 = try loopExitPhiAssignments(module, names, ctx, i, func_idx, loop_merge_label.?, arena, null);
                            if (lmp_assigns2.len > 0) {
                                try w.print("if (!({s})) {{ {s}break; }}\n", .{ inlined3 orelse condition, lmp_assigns2 });
                            } else {
                                try w.print("if (!({s})) {{ break; }}\n", .{inlined3 orelse condition});
                            }
                            // #wrap-backedge: twin of the true_is_break case (the
                            // graphicsfuzz_059 shape: false->merge, true->header).
                            try emitWrapBackedgePhiUpdates(module, names, &phi_updates, &loop_stack, loop_header_label, loop_continue_label, true_label, w, indent);
                            pending_merge = null;
                            i = skipBreakArm(module, i, false_label, loop_merge_label.?);
                        } else if (true_is_continue) {
                            // Emit phi computation + updates before continue, inside the if block
                            // In SPIR-V, continue goes to continue block which computes phi values
                            // In WGSL, we must compute phi values before the continue keyword.
                            // NOTE: unlike the break paths we do NOT inline the condition here —
                            // the body condition instruction is emitted eagerly by the main
                            // dispatch (it is not in the deferred loop-header region), so it
                            // already exists as a `let`; inlining would leave that `let` dangling
                            // AND duplicate the expression. Referencing the existing name is clean.
                            try writeInd(w, indent);
                            try w.print("if ({s}) {{\n", .{condition});
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
                                                    try emitSimpleInstruction(module, names, &ctx.inline_exprs, cbinst, w, alloc, arena, indent + 1, wrapped_members, matrix_outputs, nonuniform_gated);
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
                                    try writeInd(w, indent + 1);
                                    try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                            }
                            try writeInd(w, indent + 1);
                            try w.writeAll("continue;\n");
                            try writeInd(w, indent);
                            try w.writeAll("}\n");
                            pending_merge = null;
                        } else if (false_is_continue) {
                            // Emit phi computation + updates before continue, inside the if block.
                            // Reference the already-emitted condition name (see true_is_continue
                            // note above — inlining here would dangle the eager `let`).
                            try writeInd(w, indent);
                            try w.print("if (!({s})) {{\n", .{condition});
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
                                                    try emitSimpleInstruction(module, names, &ctx.inline_exprs, cbinst, w, alloc, arena, indent + 1, wrapped_members, matrix_outputs, nonuniform_gated);
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
                                    try writeInd(w, indent + 1);
                                    try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                            }
                            try writeInd(w, indent + 1);
                            try w.writeAll("continue;\n");
                            try writeInd(w, indent);
                            try w.writeAll("}\n");
                            pending_merge = null;
                        } else {
                            // Regular if/else
                            try writeInd(w, indent);
                            try w.print("if ({s}) {{\n", .{condition});
                            try merge_stack.append(arena, merge_label);
                            // Save the ENCLOSING if's pending_false_label before this
                            // if overwrites it; restored when this if's merge closes.
                            try false_label_stack.append(arena, pending_false_label);
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
                    // #wgsl-region-continue: a TOP-LEVEL branch to the enclosing
                    // loop's continue block, inside a switch-case REGION. In the main
                    // walk the continue block follows later in the instruction stream
                    // (structured order), so the `.Branch` continue-target skip below
                    // is exact. In region mode the walk STOPS at the switch merge and
                    // the continue block sits after it, never reached. Skipping the
                    // branch there let the walk fall through into the next block in
                    // the stream, which on loop-dominator-and-switch-default is a
                    // DIFFERENT case arm's body: the default arm's inner loop merged
                    // straight to the outer continue, the dropped branch leaked the
                    // case-0 store into the default arm, and the arm then fell out of
                    // the switch so the outer-loop tail ran on the continue path too
                    // (three silent-wrongs on one wire; naga-valid either way). The
                    // case's `continue;` (the same spelling emitSwitchArmTerminator
                    // uses) is exact and ENDS the region: control goes to the
                    // enclosing loop's `continuing` block, which the parent walk owns
                    // (so the outer loop's phi updates are NOT emitted inline). This
                    // is checked against the RANGE's inherited continue label, not
                    // `loop_continue_label`: the region's own innermost loop may have
                    // just closed, in which case the pop-to-empty below already nulled
                    // the live labels even though the region is still inside the outer
                    // loop. Only at region top level (no open construct): inside a
                    // construct the continue wires go through the BranchConditional
                    // continue arms above.
                    if (range != null) {
                        if (range.?.loop_continue) |rc| {
                            if (target == rc and if_depth == 0 and loop_stack.items.len == 0) {
                                try hoistSweepAndFlush(&hoist_pending, alloc, &ctx.hoisted_ids, names, w_out);
                                try writeIndentStatic(w_out, indent);
                                try w_out.writeAll("continue;\n");
                                return;
                            }
                        }
                    }
                    // Check for loop-related branches
                    if (in_loop) {
                        if (target == loop_header_label) {
                            // Back edge — emit phi updates for THIS loop only
                            if (loop_stack.items.len > 0) {
                                const cur = &loop_stack.items[loop_stack.items.len - 1];
                                var idx: usize = cur.phi_start;
                                while (idx < cur.phi_end) : (idx += 1) {
                                    const pu = phi_updates.items[idx];
                                    const res_name = names.get(pu.result_id) orelse continue;
                                    const val_name = names.get(pu.value_id) orelse continue;
                                    try writeInd(w, indent);
                                    try w.print("{s} = {s};\n", .{ res_name, val_name });
                                }
                                // #loop-continue-deadincr: close the `continuing {}` block
                                // (opened at the continue label). The increment + these phi
                                // updates are now inside it, so a body `continue` reaches them.
                                if (cur.continuing_open) {
                                    indent -= 1;
                                    try writeInd(w, indent);
                                    try w.writeAll("}\n");
                                    cur.continuing_open = false;
                                }
                            }
                            continue;
                        }
                        if (loop_continue_label != null and target == loop_continue_label.?) {
                            // Branch to continue block — skip
                            continue;
                        }
                        // #loop-break-on-selection-merge: OpBranch to the enclosing loop's
                        // merge is a structured break from a side-effecting break block (the
                        // block's side effects were already emitted inline by the main walker
                        // before this OpBranch). The BranchConditional arms above catch the
                        // direct / pure-trampoline break; this catches the store-then-branch
                        // case (mandelbrot-loop on unoptimized SPIR-V). break skips continuing{}.
                        if (loop_merge_label != null and target == loop_merge_label.?) {
                            // #wgsl-loop-merge-phi: a side-effecting break block's
                            // OpBranch to the loop merge must assign the merge phis
                            // BEFORE breaking (loop_break_flag_valid: the flag/value
                            // carriers stayed at their zero-init -- valid WGSL, wrong
                            // values). Pred = the current (breaking) block.
                            const lmp_side = try loopExitPhiAssignments(module, names, ctx, i, func_idx, loop_merge_label.?, arena, null);
                            try writeInd(w, indent);
                            if (lmp_side.len > 0) {
                                try w.print("{{ {s}break; }}\n", .{lmp_side});
                            } else {
                                try w.writeAll("break;\n");
                            }
                            continue;
                        }
                    }
                    // Emit selection phi updates when branching to merge block
                    if (ctx.sel_phis.count() > 0) {
                        if (ctx.sel_phis.get(target)) |phi_list| {
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
                                        try writeInd(w, indent);
                                        try w.print("{s} = {s};\n", .{ res_name, val_name });
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
                                try writeInd(w, indent);
                                try w.writeAll("} else {");
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
                        // #loop-continue-deadincr: open a `continuing {}` block. The
                        // continue-construct content (counter increment) + the back-edge phi
                        // updates are emitted inside it, so a body `continue` (which jumps to
                        // the continuing block) reaches them — matching a real `for`.
                        if (loop_stack.items.len > 0) {
                            const top = &loop_stack.items[loop_stack.items.len - 1];
                            if (top.emit_continuing) {
                                try writeInd(w, indent);
                                try w.writeAll("continuing {\n");
                                indent += 1;
                                top.continuing_open = true;
                            }
                        }
                        continue;
                    }
                    // Check if this label matches a loop merge (close loop)
                    if (loop_stack.items.len > 0) {
                        const top = loop_stack.items[loop_stack.items.len - 1];
                        if (label_id == top.merge) {
                            indent -= 1;
                            try writeInd(w, indent);
                            try w.writeAll("}\n"); // close loop
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
                    // A DIVERGING true-branch (ended in return/discard/unreachable, so
                    // it never OpBranch'd to the merge) means the `.Branch` handler never
                    // emitted the `} else {` -- control reaches the false-branch label
                    // directly with the else still pending. Open the else here so the
                    // false branch nests correctly instead of leaking into the (still
                    // open) then block after the return. Without this, an
                    // `if (a) { return x; } else if (b) { ... }` return-chain collapsed
                    // into the first then-block as dead code and dropped the trailing
                    // returns -> naga "missing return". Mirrors the Branch-handler else
                    // emission (net indent unchanged; the `if` stays open). (#170)
                    if (if_depth > 0 and pending_false_label != null and label_id == pending_false_label.?) {
                        indent -= 1;
                        try writeInd(w, indent);
                        try w.writeAll("} else {\n");
                        indent += 1;
                        pending_false_label = null;
                    }
                    // Check if this label matches an if merge (close if)
                    if (if_depth > 0 and merge_stack.items.len > 0) {
                        const cur_merge = merge_stack.items[merge_stack.items.len - 1];
                        if (label_id == cur_merge) {
                            indent -= 1;
                            try writeInd(w, indent);
                            try w.writeAll("}");
                            try w.writeAll("\n");
                            _ = merge_stack.pop();
                            // Restore the enclosing if's pending_false_label (mirrors
                            // the save in the BranchConditional Regular if/else arm).
                            if (false_label_stack.items.len > 0) {
                                pending_false_label = false_label_stack.pop().?;
                            }
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
                                .LoopMerge => {
                                    is_loop_header = true;
                                    break;
                                },
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
                        // Local-var name collision was deduped in the pre-pass before
                        // any name-resolution stage ran; names[rid] is already the unique
                        // emitted name and ctx.declared_local_names is already populated. (#170)
                        const vn = names.get(inst.words[2]) orelse "v";
                        try writeInd(w, indent);
                        // #476: OpVariable Function with an Initializer operand (word[4]) —
                        // emit it, else the local reads zero before any store (silent-wrong).
                        const finit: ?[]const u8 = if (inst.words.len >= 5) names.get(inst.words[4]) else null;
                        if (finit) |in| {
                            try w.print("var {s}: {s} = {s};\n", .{ vn, rt, in });
                        } else {
                            try w.print("var {s}: {s};\n", .{ vn, rt });
                        }
                    } else if (sc == .Private) {
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const vn = names.get(inst.words[2]) orelse "v";
                        try writeInd(w, indent);
                        try w.print("var {s}: {s};\n", .{ vn, rt });
                    }
                    // Output/Input/Uniform/UniformConstant variables handled in entry point setup
                }
            },

            // Load
            .Load => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "var";
                // Single-store private forwarding: this load reads the value
                // the one dominating entry-block store wrote; alias the result
                // to that value's name and emit no declaration at all. See
                // buildSingleStorePrivateForwarding for the subgroup-uniformity
                // rationale and the qualification rules.
                if (forward_private_stores.get(inst.words[3])) |fwd_value| {
                    if (names.get(fwd_value)) |vn| {
                        const a = try alloc.dupe(u8, vn);
                        if (try names.fetchPut(inst.words[2], a)) |old| alloc.free(old.value);
                        continue;
                    }
                }
                // #170 (F): a plain load of a `shared` atomic scalar lowers to
                // atomicLoad. Materialize as a `let` (one atomic read) so a
                // multi-use value isn't re-read per use. The result id is already
                // named (result_name), so downstream uses resolve to it.
                if (atomic_vars.contains(inst.words[3])) {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = atomicLoad(&{s});\n", .{ result_name, rt, ptr });
                    continue;
                }
                // #wgsl-atomic-field: a plain load of an SSBO struct field that
                // collectAtomicFields declared atomic<T> also lowers to atomicLoad
                // (naga: "atomic variables cannot be accessed directly"). The pointer
                // is an OpAccessChain into the struct, not a direct Workgroup/Private
                // var. Materialize as a `let` for a single atomic read, like above.
                if (resolveAtomicFieldAccess(module, inst.words[3], atomic_fields) != null) {
                    const ac = getDef(module, inst.words[3]) orelse continue;
                    const af_expr = try buildAccessExpr(module, names, ac.words[3], ac.words[4..], alloc, wrapped_members);
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = atomicLoad(&{s});\n", .{ result_name, rt, af_expr });
                    alloc.free(af_expr);
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
                } else if (ctx.inline_loads.contains(inst.words[2])) {
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
                    try writeInd(w, indent);
                    try w.print("{s} {s}: {s} = {s};\n", .{ let_or_var, result_name, rt, expr });
                    if (expr_allocated) alloc.free(expr);
                }
            },

            // Store
            .Store => {
                // Skip store to output variable when doing direct return
                if (skip_store_target != null and inst.words[1] == skip_store_target.?) continue;
                // Skip stores to MRT output variables
                if (skip_store_targets != null and skip_store_targets.?.contains(inst.words[1])) continue;
                // Dead store under single-store private forwarding: every load
                // of this var is aliased to the stored value, so the store has
                // no reader (and the var has no declaration to assign to).
                if (forward_private_stores.contains(inst.words[1])) continue;
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
                // #wgsl-atomic-field: a plain store to an SSBO atomic field lowers
                // to atomicStore for the same reason as the Workgroup-scalar case.
                if (resolveAtomicFieldAccess(module, inst.words[1], atomic_fields) != null) {
                    const ac = getDef(module, inst.words[1]) orelse continue;
                    const af_expr = try buildAccessExpr(module, names, ac.words[3], ac.words[4..], alloc, wrapped_members);
                    const aval = names.get(inst.words[2]) orelse "0";
                    try writeInd(w, indent);
                    try w.print("atomicStore(&{s}, {s});\n", .{ af_expr, aval });
                    alloc.free(af_expr);
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
                // A store THROUGH a row_major matrix would assign through
                // `transpose(...)` -- invalid WGSL (naga: "expected `;`"). Fail
                // loudly rather than emit it; mirrors the MSL backend's guard.
                if (getDef(module, inst.words[1])) |ptr| {
                    if (ptr.op == .AccessChain and ptr.words.len >= 4 and
                        findRowMajorMatrix(module, ptr.words[3], ptr.words[4..]) != null)
                        return error.UnsupportedRowMajorMatrixStore;
                }
                // #rm-store: a WHOLE-STRUCT store into a local whose type
                // contains row_major matrix members must leave RAW bytes behind
                // (every read transposes, `findRowMajorMatrix`). A RAW value (a
                // struct copied from the buffer) already holds raw bytes -- plain
                // store. A LOGICAL value (a CompositeConstruct of the decorated
                // type) must be transposed member-wise after the copy;
                // unprovable provenance fails loudly rather than store one
                // branch's bytes wrongly.
                if (getDef(module, inst.words[1])) |dst| {
                    if (dst.op == .Variable and dst.words.len >= 4 and
                        @as(spirv.StorageClass, @enumFromInt(dst.words[3])) == .Function)
                    {
                        const pptr = getDef(module, dst.words[1]);
                        if (pptr != null and pptr.?.op == .TypePointer and pptr.?.words.len >= 4) {
                            const pty = getDef(module, pptr.?.words[3]);
                            if (pty != null and pty.?.op == .TypeStruct and
                                structContainsRowMajorMatrix(module, pptr.?.words[3]))
                            {
                                const tgt = names.get(inst.words[1]) orelse "v";
                                const val = names.get(inst.words[2]) orelse "0";
                                switch (valueBytesProvenance(module, inst.words[2], 0)) {
                                    .raw => {}, // plain store below keeps raw bytes
                                    .logical => {
                                        try writeInd(w, indent);
                                        try w.print("{s} = {s};\n", .{ tgt, val });
                                        try writeRowMajorStructCompensation(module, pptr.?.words[3], tgt, val, "", w, indent);
                                        continue;
                                    },
                                    .unknown => return error.UnsupportedRowMajorMatrixStore,
                                }
                            }
                        }
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
                try writeInd(w, indent);
                try w.print("{s} = {s};\n", .{ expr, val });
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
                // A MATRIX result has no single-argument constructor: `mat3(v,v,v)`
                // must stay `mat3x3f(v, v, v)`, not collapse to the naga-rejected cast
                // `mat3x3f(v)`. The broadcast/extract-collapse simplifications below are
                // only valid for vector results, so exclude matrices like structs.
                const is_matrix_result = isMatrixType(module, inst.words[1]);
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
                if (!is_struct_result and !is_matrix_result and all_same and num_comps > 1 and first_comp != null) {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, first_comp.? });
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
                    // Only a VECTOR source may be collapsed to swizzle notation
                    // (`v.x, v.y` → `v.xy`). A struct or ARRAY source has no swizzle —
                    // `arr[0], arr[1], …` must stay element accesses, not `arr.xyzw`
                    // (naga rejects a swizzle on an array; `float a[4]` fed to
                    // `vec4(a[0],a[1],a[2],a[3])` was silently emitted as `a.xyzw`).
                    var src_is_aggregate = false;
                    if (lead_source) |ls| {
                        const src_type_for_swizzle = resolveTypeOf(module, ls);
                        if (src_type_for_swizzle) |st| {
                            const st_def2 = getDef(module, st);
                            if (st_def2) |sd3| {
                                if (sd3.op == .TypeStruct or sd3.op == .TypeArray or sd3.op == .TypeRuntimeArray) src_is_aggregate = true;
                            }
                        }
                    }
                    if (lead_count >= 2 and lead_source != null and !src_is_aggregate and !is_struct_result and !is_matrix_result) {
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
                        try writeInd(w, indent);
                        try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, parts.items });
                    } else {
                        // General case: emit all components
                        var parts = std.ArrayList(u8).initCapacity(alloc, 128) catch return;
                        defer parts.deinit(alloc);
                        for (inst.words[3..], 0..) |comp_id, ci| {
                            if (ci > 0) try parts.appendSlice(alloc, ", ");
                            const comp_name = names.get(comp_id) orelse "0";
                            try parts.appendSlice(alloc, comp_name);
                        }
                        try writeInd(w, indent);
                        try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, parts.items });
                    }
                }
            },

            // CompositeExtract
            .CompositeExtract => {
                // Skip dead extracts or inlined extracts (name was propagated to use site)
                if (ctx.dead_extracts.contains(inst.words[2]) or ctx.inline_loads.contains(inst.words[2])) continue;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                // Extracting from an OpConstantNull IS the zero value of the
                // extract's own result type. naga emits this shape for every
                // `return Struct();` in a flattened-entry shader (OpConstantNull of
                // the io struct + one extract per builtin/location). The generic
                // path below would emit `<StructName>().<member>`, but the io
                // struct is NOT declared in the output (the entry signature was
                // reconstructed to builtin returns), which is an undeclared
                // identifier at exit 0. Fold the whole extract to the zero literal.
                if (getDef(module, inst.words[3])) |bd| {
                    if (bd.op == .ConstantNull) {
                        if (zeroLiteralOfType(module, inst.words[1], names, alloc)) |z| {
                            try writeInd(w, indent);
                            try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, z });
                            continue;
                        }
                    }
                }
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
                // #rm-extract: an extract that reaches a row-major SQUARE matrix
                // member inside a RAW composite value (a whole-struct or array
                // load from the buffer: `%v = OpLoad %RowMajor %p;
                // OpCompositeExtract %mat4 %v 0`) reads the TRANSPOSE of the
                // logical matrix -- WGSL has no row_major storage, so the raw
                // column-major read of row-major bytes is M^T. The same
                // compensation `buildAccessExpr` applies when the matrix is
                // reached through an access chain. Provenance decides: a
                // CompositeConstruct of the same struct type holds LOGICAL
                // bytes and must stay untransposed; unprovable sources fail
                // loudly rather than guess.
                if (inst.words.len > 4) {
                    if (findRowMajorExtract(module, inst.words[3], inst.words[4..])) |hit| {
                        switch (valueBytesProvenance(module, inst.words[3], 0)) {
                            .raw => {
                                var texpr = std.ArrayList(u8).initCapacity(alloc, 64) catch return;
                                defer texpr.deinit(alloc);
                                try texpr.appendSlice(alloc, "transpose(");
                                try texpr.appendSlice(alloc, composite);
                                try appendExtractPrefix(module, inst.words[3], inst.words[4 .. hit.boundary + 5], &texpr, alloc);
                                try texpr.appendSlice(alloc, ")");
                                try appendMatrixTailLiterals(module, hit.matrix_tid, inst.words[hit.boundary + 5 ..], &texpr, alloc);
                                try writeInd(w, indent);
                                try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, texpr.items });
                                continue;
                            },
                            .logical => {}, // registers hold the logical matrix: plain path
                            .unknown => return error.UnsupportedRowMajorExtractProvenance,
                        }
                    }
                }
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
                                // frexp/modf struct result → WGSL builtin fields (.fract/
                                // .exp/.whole), not the generic `._N`. (#170)
                                const mname = frexpModfField(module, inst.words[3], idx) orelse getMemberName(module, ct, idx, &mname_buf);
                                try expr.print(alloc, ".{s}", .{mname});
                                if (idx + 2 < cti.words.len) current_type = cti.words[idx + 2] else current_type = null;
                                continue;
                            } else if (cti.op == .TypeVector) {
                                const sw = switch (idx) {
                                    0 => ".x",
                                    1 => ".y",
                                    2 => ".z",
                                    3 => ".w",
                                    else => ".x",
                                };
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
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, expr.items });
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
            .VectorShuffle => try emitVectorShuffleWgsl(module, names, inst, w, arena, indent),

            // Arithmetic
            .FAdd, .IAdd => try emitBinOp(module, names, &ctx.inline_exprs, inst, "+", w, arena, indent),
            .FSub, .ISub => try emitBinOp(module, names, &ctx.inline_exprs, inst, "-", w, arena, indent),
            .FMul, .IMul => try emitBinOp(module, names, &ctx.inline_exprs, inst, "*", w, arena, indent),
            .FDiv, .SDiv, .UDiv => try emitBinOp(module, names, &ctx.inline_exprs, inst, "/", w, arena, indent),
            .FMod => try emitFMod(module, names, &ctx.inline_exprs, inst, w, arena, indent),
            .UMod, .SRem, .FRem => try emitBinOp(module, names, &ctx.inline_exprs, inst, "%", w, arena, indent),
            // OpSMod is floored (sign of DIVISOR); WGSL `%` is truncated (sign of dividend =
            // OpSRem), so `((x % y) + y) % y` adjusts it to floored for every sign combination
            // (verified exhaustively via naga const_assert). Kept out of the inline/symbol
            // tables below so it always materializes through emitSMod, never a bare `%`. (#170)
            .SMod => try emitSMod(module, names, &ctx.inline_exprs, inst, w, arena, indent),
            // All three shifts share emitShift, which applies the u32/vecN<u32>
            // amount cast and the #170 constant over-shift mask. ShiftRightArithmetic
            // (signed `>>`) used to route through the generic emitBinOp, which did
            // neither — a signed const over-shift (or even an in-range signed shift,
            // needing the u32 cast) was naga-rejected (silent-wrong).
            .ShiftLeftLogical => try emitShift(module, names, &ctx.inline_exprs, inst, "<<", w, arena, indent),
            .ShiftRightLogical, .ShiftRightArithmetic => try emitShift(module, names, &ctx.inline_exprs, inst, ">>", w, arena, indent),
            .FNegate, .SNegate => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent);
                try w.print("let {s}: {s} = -{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .VectorTimesScalar, .MatrixTimesScalar => try emitBinOp(module, names, &ctx.inline_exprs, inst, "*", w, arena, indent),
            .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => {
                // WGSL uses mul() — wait, WGSL doesn't have mul(). Use matrix multiplication operator *
                try emitBinOp(module, names, &ctx.inline_exprs, inst, "*", w, arena, indent);
            },

            // OuterProduct(u, v): u is the result's column vector type (R rows),
            // v supplies the columns (C components). The result is a CxR matrix
            // whose column i is `u * v[i]`. WGSL has no outerProduct builtin —
            // construct the matrix explicitly (matCxR(u*v.x, u*v.y, ...)).
            .OuterProduct => try emitOuterProduct(module, names, inst, w, arena, indent),

            // Dot product
            .Dot => try emitCall(module, names, inst, "dot", w, arena, indent),

            // Comparisons
            .FOrdEqual, .IEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, "==", w, arena, indent),
            // WGSL `!=` follows IEEE-754, so it is the *unordered* not-equal (true
            // when either operand is NaN) — exactly OpFUnordNotEqual. glslang emits
            // FUnordNotEqual for every GLSL float `!=`/`notEqual()`. (#170)
            .FUnordNotEqual, .INotEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, "!=", w, arena, indent),
            .FOrdNotEqual => try emitOrderedNotEqual(module, names, &ctx.inline_exprs, inst, w, arena, indent),
            .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(module, names, &ctx.inline_exprs, inst, "<", w, arena, indent),
            .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(module, names, &ctx.inline_exprs, inst, ">", w, arena, indent),
            .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, "<=", w, arena, indent),
            .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, ">=", w, arena, indent),
            // Unordered float inequalities: `!(complementary ordered op)`, exact on
            // NaN (see emitUnorderedCompare). NOT `<`/`>=` -- those are ordered and
            // silent-wrong when an operand is NaN. (#170)
            .FUnordLessThan => try emitUnorderedCompare(module, names, &ctx.inline_exprs, inst, ">=", w, arena, indent),
            .FUnordGreaterThan => try emitUnorderedCompare(module, names, &ctx.inline_exprs, inst, "<=", w, arena, indent),
            .FUnordLessThanEqual => try emitUnorderedCompare(module, names, &ctx.inline_exprs, inst, ">", w, arena, indent),
            .FUnordGreaterThanEqual => try emitUnorderedCompare(module, names, &ctx.inline_exprs, inst, "<", w, arena, indent),
            // Unordered equality: (a==b) || isNaN(a) || isNaN(b), not the naive ordered
            // `==` (false on NaN). No single-operator complement, so a direct lowering. (#170)
            .FUnordEqual => try emitUnorderedEqual(module, names, &ctx.inline_exprs, inst, w, arena, indent),

            // Logical
            .LogicalOr => try emitBinOp(module, names, &ctx.inline_exprs, inst, "||", w, arena, indent),
            .LogicalAnd => try emitBinOp(module, names, &ctx.inline_exprs, inst, "&&", w, arena, indent),
            // Boolean equality (GLSL bool `==`/`!=`, `equal`/`notEqual` on bvecN).
            // WGSL `==`/`!=` apply to bool and are componentwise on vecN<bool>. (#170)
            .LogicalEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, "==", w, arena, indent),
            .LogicalNotEqual => try emitBinOp(module, names, &ctx.inline_exprs, inst, "!=", w, arena, indent),
            .LogicalNot => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent);
                try w.print("let {s}: {s} = !{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "true" });
            },

            // Select (ternary)
            .Select => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const cond = names.get(inst.words[3]) orelse "c";
                const true_val = names.get(inst.words[4]) orelse "t";
                const false_val = names.get(inst.words[5]) orelse "f";
                // WGSL select() only works with scalars and vectors — a struct or
                // ARRAY result has no select() form and must lower to var + if/else
                // (naga: "unexpected argument type for select" on `array<f32,N>`).
                if (std.mem.startsWith(u8, rt, "struct") or std.mem.containsAtLeast(u8, rt, 1, "Struct") or
                    std.mem.startsWith(u8, rt, "array") or
                    (inst.words.len > 1 and (isStructType(module, inst.words[1]) or isArrayType(module, inst.words[1]))))
                {
                    try writeInd(w, indent);
                    try w.print("var {s}: {s};\n", .{ result_name, rt });
                    try writeInd(w, indent);
                    try w.print("if ({s}) {{\n", .{cond});
                    try writeInd(w, indent + 1);
                    try w.print("{s} = {s};\n", .{ result_name, true_val });
                    try writeInd(w, indent);
                    try w.writeAll("} else {\n");
                    try writeInd(w, indent + 1);
                    try w.print("{s} = {s};\n", .{ result_name, false_val });
                    try writeInd(w, indent);
                    try w.writeAll("}\n");
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
                }
            },

            // Conversions
            .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU, .UConvert, .SConvert, .FConvert => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const val = names.get(inst.words[3]) orelse "0";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, val });
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
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, val });
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = bitcast<{s}>({s});\n", .{ result_name, rt, rt, val });
                }
            },

            // Texture sampling
            .ImageSampleImplicitLod => {
                // WGSL cannot filter integer textures — texture(isampler/usampler)
                // has no faithful sample form (textureLoad only). (#170)
                if (isIntegerSampledImage(module, inst.words[3])) return error.UnsupportedIntegerTextureSample;
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
                // #wgsl-uniformity-8k2: this sample sits in non-uniform control
                // flow (the uniformity prepass marked its result id), so the
                // implicit-Lod builtins below must NOT be emitted: tint and naga
                // reject them there ("textureSample must only be called from
                // uniform control flow"). Lower to textureSampleLevel with the
                // level pinned to 0, the same move SPIRV-Cross's MSL backend
                // makes for a constant-zero gradient (promoted to level(0)).
                // A Bias operand is DROPPED: WGSL has no textureQueryLod to fold
                // a bias into an explicit level and textureSampleBias is gated
                // exactly like textureSample, so the bias is lost rather than the
                // whole shader honest-errored (erroring here is the black-player
                // failure mode this bug class caused on wintty.io).
                const nonuniform_flow = nonuniform_gated.contains(inst.words[2]);
                // Image-operands mask (words[5]). A `Bias` (0x1) operand carries an
                // LOD bias (GLSL texture(s, P, bias)). WGSL spells this
                // textureSampleBias(t, s, coord, [layer,] bias [, offset]) — dropping
                // the bias is silent-wrong. Bias may pair with ConstOffset (0x8); any
                // other operand bit has no faithful WGSL form → honest-error. Mirrors
                // the Grad handling in ImageSampleExplicitLod (#319).
                const mask: u32 = if (inst.words.len > 5) inst.words[5] else 0;
                if ((mask & 0x1) != 0) {
                    if ((mask & ~@as(u32, 0x1 | 0x8)) != 0) return error.UnsupportedImageOperands;
                    // textureSampleBias is FRAGMENT-ONLY in WGSL — a bias outside a
                    // fragment shader has no faithful form. Honest-error.
                    if (module.execution_model != .Fragment) return error.UnsupportedImageOperands;
                    // And it has NO depth-texture overload at all: a biased sample of
                    // a depth image has no faithful WGSL form. Honest-error rather
                    // than emit a call naga rejects. (#wgsl-cts)
                    if (shape.depth) return error.UnsupportedImageOperands;
                    // Operands follow bit order: bias (words[6]), then an optional
                    // ConstOffset (words[7]). Truncated/malformed SPIR-V honest-errors
                    // rather than indexing out of bounds (don't panic on bad input).
                    if (inst.words.len <= 6) return error.UnsupportedImageOperands;
                    const bias = names.get(inst.words[6]) orelse "0";
                    // ConstOffset (0x8) appends a trailing const-offset arg. A mask
                    // that CLAIMS the offset but whose operand word is truncated away
                    // must honest-error, not silently drop the claimed offset
                    // (silent-wrong) — mirrors the gather/non-Bias offset guards.
                    var off_suffix: []const u8 = "";
                    if ((mask & 0x8) != 0) {
                        if (inst.words.len <= 7) return error.UnsupportedImageOperands;
                        off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[7]) orelse "vec2<i32>(0)"});
                    }
                    // Pick the builtin and its trailing scalar ONCE, then print
                    // once per coordinate shape, the way the Dref arms below
                    // do. The four parallel format strings this replaces are
                    // exactly how the invalid float depth level (F1) shipped:
                    // a rule fixed in one copy and missed in the others.
                    const bias_builtin: []const u8 = if (nonuniform_flow) "textureSampleLevel" else "textureSampleBias";
                    // level pinned to 0, bias dropped (see above)
                    const bias_last: []const u8 = if (nonuniform_flow) "0.0" else bias;
                    try writeInd(w, indent);
                    if (shape.arrayed) {
                        const cs = arrayedCoordSwizzle(shape.comps);
                        const ls = arrayedLayerSwizzle(shape.comps);
                        try w.print("let {s}: {s} = {s}({s}, {s}, {s}{s}, i32(round({s}{s})), {s}{s});\n", .{ result_name, rt, bias_builtin, tex_name, sampler_arg, coord, cs, coord, ls, bias_last, off_suffix });
                    } else {
                        try w.print("let {s}: {s} = {s}({s}, {s}, {s}, {s}{s});\n", .{ result_name, rt, bias_builtin, tex_name, sampler_arg, coord, bias_last, off_suffix });
                    }
                } else {
                    // Non-Bias path. The only image operand WGSL's plain textureSample
                    // can carry is a CONSTANT ConstOffset (0x8) — GLSL textureOffset.
                    // With Bias absent the offset sits at words[6] (bit order). Any
                    // other operand bit (e.g. the runtime Offset 0x10 of a dynamic
                    // textureOffset) has no faithful textureSample form → honest-error
                    // rather than silently dropping it. Mirrors the Bias audit above
                    // and the Grad audit in ImageSampleExplicitLod (#319/#314/#170).
                    if ((mask & ~@as(u32, 0x8)) != 0) return error.UnsupportedImageOperands;
                    var off_suffix: []const u8 = "";
                    if ((mask & 0x8) != 0) {
                        // ConstOffset claimed but truncated SPIR-V → honest-error, not
                        // an out-of-bounds index or a silent offset drop.
                        if (inst.words.len <= 6) return error.UnsupportedImageOperands;
                        off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[6]) orelse "vec2<i32>(0)"});
                    }
                    // Same Dref-arm shape as the Bias path: decide the three
                    // things that vary once, print once per coordinate shape.
                    // Seven parallel format strings here is how the invalid
                    // float depth level (F1) reached a release.
                    const builtin: []const u8 = if (nonuniform_flow) "textureSampleLevel" else "textureSample";
                    // The level pin (#wgsl-uniformity-8k2). DEPTH takes an
                    // INTEGER level (`0`, not `0.0`): WGSL's depth overload
                    // constrains L to i32/u32, so the f32 literal is a tint AND
                    // naga reject. Same rule the ImageSampleExplicitLod depth
                    // arm applies with its i32() wrap. (#wgsl-cts)
                    const level_arg: []const u8 = if (!nonuniform_flow) "" else if (shape.depth) ", 0" else ", 0.0";
                    // WGSL's non-comparison DEPTH sample returns a SCALAR f32,
                    // while SPIR-V's result is the vec4: widen by splat so the
                    // declared vec4 let still typechecks (naga's own WGSL front
                    // lowers `textureSample(depth2d, ...)` to exactly this
                    // OpImageSample* + extract-0 shape). (#wgsl-cts)
                    const splat_open: []const u8 = if (shape.depth) try std.fmt.allocPrint(arena, "{s}(", .{rt}) else "";
                    const splat_close: []const u8 = if (shape.depth) ")" else "";
                    try writeInd(w, indent);
                    if (shape.arrayed) {
                        const cs = arrayedCoordSwizzle(shape.comps);
                        const ls = arrayedLayerSwizzle(shape.comps);
                        try w.print("let {s}: {s} = {s}{s}({s}, {s}, {s}{s}, i32(round({s}{s})){s}{s}){s};\n", .{ result_name, rt, splat_open, builtin, tex_name, sampler_arg, coord, cs, coord, ls, level_arg, off_suffix, splat_close });
                    } else {
                        try w.print("let {s}: {s} = {s}{s}({s}, {s}, {s}{s}{s}){s};\n", .{ result_name, rt, splat_open, builtin, tex_name, sampler_arg, coord, level_arg, off_suffix, splat_close });
                    }
                }
            },

            .ImageSampleExplicitLod => {
                // Integer textures are non-filterable in WGSL (textureLoad only). (#170)
                if (isIntegerSampledImage(module, inst.words[3])) return error.UnsupportedIntegerTextureSample;
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
                const shape = arrayedSampleShape(module, inst.words[3]);
                // Image-operands mask (words[5]) selects the explicit-LOD variant.
                const mask: u32 = if (inst.words.len > 5) inst.words[5] else 0;
                // Grad (0x4): explicit ddx/ddy gradients (GLSL textureGrad). Operands
                // follow bit order — ddx (words[6]), ddy (words[7]), then an optional
                // ConstOffset (0x8) at words[8]. WGSL spells this textureSampleGrad;
                // the gradient must NOT be squeezed into textureSampleLevel's scalar
                // LOD slot (that was both wrong and a naga reject). Any operand bit
                // beyond Grad|ConstOffset has no faithful WGSL form → honest-error.
                if ((mask & 0x4) != 0) {
                    if ((mask & ~@as(u32, 0x4 | 0x8)) != 0) return error.UnsupportedImageOperands;
                    // textureSampleGrad has NO depth-texture overload: a gradient
                    // sample of a depth image has no faithful WGSL form. (#wgsl-cts)
                    if (shape.depth) return error.UnsupportedImageOperands;
                    // A well-formed Grad carries BOTH gradients (ddx=words[6],
                    // ddy=words[7]); truncated/malformed SPIR-V honest-errors rather
                    // than indexing out of bounds (don't panic on bad input).
                    if (inst.words.len <= 7) return error.UnsupportedImageOperands;
                    const ddx = names.get(inst.words[6]) orelse "0";
                    const ddy = names.get(inst.words[7]) orelse "0";
                    // ConstOffset (0x8) appends a trailing const-offset arg (after
                    // ddx/ddy). A mask that CLAIMS the offset but whose operand word
                    // is truncated away must honest-error, not silently drop the
                    // claimed offset (silent-wrong) — mirrors the Bias-arm guard.
                    var off_suffix: []const u8 = "";
                    if ((mask & 0x8) != 0) {
                        if (inst.words.len <= 8) return error.UnsupportedImageOperands;
                        off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[8]) orelse "vec2<i32>(0)"});
                    }
                    if (shape.arrayed) {
                        const cs = arrayedCoordSwizzle(shape.comps);
                        const ls = arrayedLayerSwizzle(shape.comps);
                        try writeInd(w, indent);
                        try w.print("let {s}: {s} = textureSampleGrad({s}, {s}, {s}{s}, i32(round({s}{s})), {s}, {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, cs, coord, ls, ddx, ddy, off_suffix });
                    } else {
                        try writeInd(w, indent);
                        try w.print("let {s}: {s} = textureSampleGrad({s}, {s}, {s}, {s}, {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, ddx, ddy, off_suffix });
                    }
                } else {
                    // Non-Grad path: explicit Lod (0x2), optionally with a CONSTANT
                    // ConstOffset (0x8) — GLSL textureLod / textureLodOffset. Operands
                    // follow bit order: lod (words[6]), then the optional offset
                    // (words[7]). Reading only the LOD and dropping the offset was
                    // silent-wrong; any operand bit beyond Lod|ConstOffset has no
                    // faithful textureSampleLevel form → honest-error. (#170, mirrors
                    // the Grad arm above.)
                    if ((mask & ~@as(u32, 0x2 | 0x8)) != 0) return error.UnsupportedImageOperands;
                    // ExplicitLod REQUIRES the Lod operand on this (non-Grad) arm; a
                    // ConstOffset-only mask is invalid SPIR-V and would misindex the
                    // lod onto the offset word. Honest-error rather than read garbage.
                    if ((mask & 0x2) == 0) return error.UnsupportedImageOperands;
                    const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                    var off_suffix: []const u8 = "";
                    if ((mask & 0x8) != 0) {
                        // ConstOffset claimed but truncated SPIR-V → honest-error.
                        if (inst.words.len <= 7) return error.UnsupportedImageOperands;
                        off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[7]) orelse "vec2<i32>(0)"});
                    }
                    // Arrayed: textureSampleLevel(t, s, coord.xy, i32(round(coord.z)), lod).
                    // Layer rounded for glslang parity (see ImageSampleImplicitLod).
                    // DEPTH: WGSL's depth form takes an i32 level (naga rejects the
                    // f32 overload) and returns a SCALAR f32, widened by splat to the
                    // SPIR-V vec4 result like ImageSampleImplicitLod. (#wgsl-cts)
                    const depth_level: []const u8 = if (shape.depth)
                        try std.fmt.allocPrint(arena, "i32({s})", .{lod})
                    else
                        lod;
                    if (shape.arrayed) {
                        const cs = arrayedCoordSwizzle(shape.comps);
                        const ls = arrayedLayerSwizzle(shape.comps);
                        try writeInd(w, indent);
                        if (shape.depth) {
                            try w.print("let {s}: {s} = {s}(textureSampleLevel({s}, {s}, {s}{s}, i32(round({s}{s})), {s}{s}));\n", .{ result_name, rt, rt, tex_name, sampler_arg, coord, cs, coord, ls, depth_level, off_suffix });
                        } else {
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}, {s}{s}, i32(round({s}{s})), {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, cs, coord, ls, depth_level, off_suffix });
                        }
                    } else {
                        try writeInd(w, indent);
                        if (shape.depth) {
                            try w.print("let {s}: {s} = {s}(textureSampleLevel({s}, {s}, {s}, {s}{s}));\n", .{ result_name, rt, rt, tex_name, sampler_arg, coord, depth_level, off_suffix });
                        } else {
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}, {s}, {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, depth_level, off_suffix });
                        }
                    }
                }
            },

            .ImageSampleDrefImplicitLod => {
                // #wgsl-uniformity-8k2: textureSampleCompare is uniformity-gated
                // just like textureSample; a Dref sample in non-uniform flow takes
                // the ungated textureSampleCompareLevel (which samples mip 0,
                // exactly the level pin the non-Dref path uses).
                const builtin: []const u8 = if (nonuniform_gated.contains(inst.words[2])) "textureSampleCompareLevel" else "textureSampleCompare";
                try emitDepthCompare(module, names, w, indent, arena, inst, builtin);
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
                    try writeInd(w, indent);
                    try w.print("return {s};\n", .{ret_name});
                } else {
                    // Entry function. The FINAL return (terminator of the last
                    // block, at top level) is collapsed into the wrapper's trailing
                    // output-struct return, so it is dropped here. A mid-body EARLY
                    // return — nested in a selection/loop, or textually before the
                    // final return — must actually exit, or later stage-IO writes
                    // overwrite the branch's output (silent-wrong).
                    // Region mode: a return inside a case region is ALWAYS early
                    // (last_return_idx stays 0 for a region, so i != 0 is naturally
                    // true -- but be explicit about the intent).
                    const is_early = range != null or i != last_return_idx or if_depth > 0 or in_loop;
                    if (is_early) {
                        switch (early_return) {
                            .none => {},
                            .stmt => |s| {
                                try writeInd(w, indent);
                                try w.print("{s}\n", .{s});
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
                            try writeInd(w, indent);
                            try w.print("let {s}: {s} = spvInverse{d}({s});\n", .{ result_name, rt, dim, m });
                        } else if (instruction == 51 or instruction == 35) {
                            const x = names.get(inst.words[5]) orelse "0";
                            const builtin = if (instruction == 51) "frexp" else "modf";
                            const second_field = if (instruction == 51) "exp" else "whole";
                            const tmp = std.fmt.allocPrint(arena, "{s}_sm", .{result_name}) catch "_sm";
                            try writeInd(w, indent);
                            try w.print("let {s} = {s}({s});\n", .{ tmp, builtin, x });
                            if (inst.words.len > 6) {
                                if (names.get(inst.words[6])) |ptr_name| {
                                    try writeInd(w, indent);
                                    try w.print("{s} = {s}.{s};\n", .{ ptr_name, tmp, second_field });
                                }
                            }
                            try writeInd(w, indent);
                            try w.print("let {s}: {s} = {s}.fract;\n", .{ result_name, rt, tmp });
                        } else if (instruction == 52 or instruction == 36) {
                            // FrexpStruct (52) / ModfStruct (36): the result IS the
                            // {fract, exp|whole} struct, consumed by OpCompositeExtract.
                            // Emit the builtin call WITHOUT a type annotation — the
                            // result type is the un-nameable builtin (`__frexp_result_*`
                            // / `__modf_result_*`); glslang's struct type name `ResType`
                            // is undefined in WGSL. The extracts are remapped to the
                            // named fields (.fract/.exp/.whole) by frexpModfField in the
                            // CompositeExtract arms. (#170)
                            const x = names.get(inst.words[5]) orelse "0";
                            const builtin = if (instruction == 52) "frexp" else "modf";
                            try writeInd(w, indent);
                            try w.print("let {s} = {s}({s});\n", .{ result_name, builtin, x });
                        } else if (scalarGeomLower(arena, module, names, instruction, inst.words[1], inst.words[5..])) |sexpr| {
                            // Scalar geometric builtin WGSL lacks (normalize/length/
                            // distance/reflect on a scalar) — emit the equivalent.
                            try writeInd(w, indent);
                            try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, sexpr });
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
                                try writeInd(w, indent);
                                try w.print("let {s}: {s} = {s}({s}({s}));\n", .{ result_name, rt, rt, func_name, args.items });
                            } else {
                                try writeInd(w, indent);
                                try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
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
                // Mirror the signature emitter's conservative inout split: only
                // multi-inout or non-void+inout callees take ptr<function> params
                // (single-inout-void keeps the return-value reassign idiom).
                const callee_use_ptr_inout = callee_inout_arg_indices.items.len >= 1 and
                    !(callee_inout_arg_indices.items.len == 1 and std.mem.eql(u8, rt, "void"));
                for (inst.words[4..], 0..) |arg_id, ai| {
                    if (ai > 0) try args.appendSlice(arena, ", ");
                    // Prefix inout (pointer) args with & so they bind to the
                    // ptr<function> params; glslang always passes an OpVariable
                    // (or AccessChain lvalue), so &<name> is a valid WGSL address.
                    var is_inout_arg = false;
                    for (callee_inout_arg_indices.items) |ii| {
                        if (ii == ai) {
                            is_inout_arg = true;
                            break;
                        }
                    }
                    if (callee_use_ptr_inout and is_inout_arg) try args.appendSlice(arena, "&");
                    try args.appendSlice(arena, names.get(arg_id) orelse "0");
                }

                if (callee_use_ptr_inout) {
                    // Pointer params propagate inout writes themselves; no
                    // caller-side reassign. Use the callee's real return type.
                    if (std.mem.eql(u8, rt, "void")) {
                        try writeInd(w, indent);
                        try w.print("{s}({s});\n", .{ func_name, args.items });
                    } else {
                        try writeInd(w, indent);
                        try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                    }
                } else if (callee_inout_arg_indices.items.len == 1 and std.mem.eql(u8, rt, "void")) {
                    // Void function with single inout param: caller reassigns
                    // e.g., v16 = out_test_0(40, v16);
                    const inout_idx = callee_inout_arg_indices.items[0];
                    if (inst.words.len > 4 + inout_idx) {
                        const inout_arg_id = inst.words[4 + inout_idx];
                        const inout_arg_name = names.get(inout_arg_id) orelse "_out";
                        try writeInd(w, indent);
                        try w.print("{s} = {s}({s});\n", .{ inout_arg_name, func_name, args.items });
                    } else {
                        try writeInd(w, indent);
                        try w.print("{s}({s});\n", .{ func_name, args.items });
                    }
                } else if (std.mem.eql(u8, rt, "void")) {
                    try writeInd(w, indent);
                    try w.print("{s}({s});\n", .{ func_name, args.items });
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                }
            },

            // Bitwise
            .BitwiseOr => try emitBinOp(module, names, &ctx.inline_exprs, inst, "|", w, arena, indent),
            .BitwiseXor => try emitBinOp(module, names, &ctx.inline_exprs, inst, "^", w, arena, indent),
            .BitwiseAnd => try emitBinOp(module, names, &ctx.inline_exprs, inst, "&", w, arena, indent),
            .Not => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeInd(w, indent);
                try w.print("let {s}: {s} = ~{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .BitReverse => try emitBitReverseWgsl(module, names, inst, w, arena, indent),
            .BitCount => try emitBitCountWgsl(module, names, inst, w, arena, indent),
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
            .BitFieldSExtract, .BitFieldUExtract => try emitBitFieldExtractWgsl(module, names, inst, w, arena, indent),

            // Derivatives. Ordered to match the SPIR-V spec numbering:
            // plain (207-209), Fine (210-212), Coarse (213-215). WGSL has a
            // direct builtin for every one of the nine variants, and in
            // UNIFORM flow that one-to-one spelling is the whole story. Out of
            // uniform flow it is a REFUSAL (#685,
            // #wgsl-uniformity-8k2-derivatives): WGSL gates all nine on
            // uniform control flow exactly as it gates textureSample, and a
            // derivative has no lowered form to downgrade to (nothing analog
            // to the textureSampleLevel pin), so the only emittable builtin
            // would be a tint reject and a black shader in the browser.
            // emitDerivative consults the uniformity prepass's marked-result
            // map and refuses exactly those, matching the sampling half's
            // verdict at the same flow information.
            .DPdx => try emitDerivative(module, names, inst, nonuniform_gated, "dpdx", w, arena, indent),
            .DPdy => try emitDerivative(module, names, inst, nonuniform_gated, "dpdy", w, arena, indent),
            .Fwidth => try emitDerivative(module, names, inst, nonuniform_gated, "fwidth", w, arena, indent),
            // Fine-quality variants (OpDPdxFine 210 / OpDPdyFine 211 /
            // OpFwidthFine 212). Previously these fell through to the honest-
            // error else branch even though WGSL can represent them directly.
            .DPdxFine => try emitDerivative(module, names, inst, nonuniform_gated, "dpdxFine", w, arena, indent),
            .DPdyFine => try emitDerivative(module, names, inst, nonuniform_gated, "dpdyFine", w, arena, indent),
            .FwidthFine => try emitDerivative(module, names, inst, nonuniform_gated, "fwidthFine", w, arena, indent),
            .DPdxCoarse => try emitDerivative(module, names, inst, nonuniform_gated, "dpdxCoarse", w, arena, indent),
            .DPdyCoarse => try emitDerivative(module, names, inst, nonuniform_gated, "dpdyCoarse", w, arena, indent),
            .FwidthCoarse => try emitDerivative(module, names, inst, nonuniform_gated, "fwidthCoarse", w, arena, indent),

            // OpQuantizeToF16 (116): quantize a 32-bit float to f16
            // precision/range, then widen back to f32. WGSL's `quantizeToF16`
            // has identical semantics (componentwise on vecN<f32>), so scalar and
            // vector share this one unary-call arm. glslang never emits this from
            // GLSL — it comes from optimizers/tools/hand-written SPIR-V consumed
            // via spirvToWGSL. (#170)
            .QuantizeToF16 => try emitCall(module, names, inst, "quantizeToF16", w, arena, indent),

            // Subgroup operations -> WGSL subgroup builtins under
            // `enable subgroups;` (emitted by the module pre-scan). This replaces
            // the #641-era consolidated refusal: the local naga cannot parse
            // `enable subgroups;`, which made EVERY subgroup op refuse (546 CTS
            // cases), but tint (dawn 5e9e5136) parses and validates the full
            // subgroups dialect, so the forms below are now measurable. MSL's
            // simd_* lowering (spirv_to_msl.zig) is the semantic reference:
            // same execution-scope reading, same operand positions, same
            // GroupOperation literal semantics (Reduce/Inclusive/Exclusive).
            .SubgroupAllKHR,
            .GroupNonUniformAll,
            .SubgroupAnyKHR,
            .GroupNonUniformAny,
            .GroupNonUniformElect,
            .GroupNonUniformBroadcast,
            .GroupNonUniformBroadcastFirst,
            .GroupNonUniformBallot,
            .GroupNonUniformShuffle,
            .GroupNonUniformShuffleXor,
            .GroupNonUniformShuffleUp,
            .GroupNonUniformShuffleDown,
            .GroupNonUniformIAdd,
            .GroupNonUniformFAdd,
            .GroupNonUniformIMul,
            .GroupNonUniformFMul,
            .GroupNonUniformSMin,
            .GroupNonUniformUMin,
            .GroupNonUniformFMin,
            .GroupNonUniformSMax,
            .GroupNonUniformUMax,
            .GroupNonUniformFMax,
            .GroupNonUniformBitwiseAnd,
            .GroupNonUniformBitwiseOr,
            .GroupNonUniformBitwiseXor,
            .GroupNonUniformQuadBroadcast,
            .GroupNonUniformQuadSwap,
            => try emitSubgroupOp(module, names, inst, w, arena, indent),

            // Subgroup families with NO faithful WGSL spelling stay refused
            // (sharply named). These are NOT gaps in the emitter below: the
            // subgroups dialect has no builtin for any of them, and emulating
            // them would require synthesizing a subgroup_invocation_id entry
            // param plus per-lane arithmetic whose result no longer matches
            // the hardware op -- a miscompile, not a lowering.
            //   AllEqual: no subgroupAllEqual in the dialect.
            //   LogicalAnd/Or/Xor: bool reductions are subgroupAll/subgroupAny;
            //     the Logical* integer forms have no overload, and their scans
            //     have nothing at all.
            //   InverseBallot/BallotBitExtract/BallotBitCount/BallotFindLSB/
            //     BallotFindMSB: ballot-bit ops; every spelling needs the
            //     invocation id, which the op itself does not carry.
            //   Rotate: no form; the delta is per-invocation.
            .GroupNonUniformAllEqual,
            .GroupNonUniformLogicalAnd,
            .GroupNonUniformLogicalOr,
            .GroupNonUniformLogicalXor,
            .GroupNonUniformInverseBallot,
            .GroupNonUniformBallotBitExtract,
            .GroupNonUniformBallotBitCount,
            .GroupNonUniformBallotFindLSB,
            .GroupNonUniformBallotFindMSB,
            .GroupNonUniformRotate,
            => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL subgroups dialect has no builtin for {s} (emulating it would miscompile)", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            },

            // Return value
            .ReturnValue => {
                const val = names.get(inst.words[1]) orelse "v";
                try writeInd(w, indent);
                try w.print("return {s};\n", .{val});
            },

            // Kill (discard in fragment)
            .Kill => {
                try writeInd(w, indent);
                try w.writeAll("discard;\n");
            },

            // Unreachable: WGSL has NO `unreachable` statement (naga parses the bare
            // word as an identifier and rejects `unreachable;`). OpUnreachable marks a
            // block control flow never reaches -- every path into it already diverged
            // (return/discard) -- so, like the MSL/HLSL/GLSL backends, emit nothing.
            // naga's own divergence analysis then sees the enclosing if/switch arms all
            // return and accepts the function without a trailing terminator. (#170)
            .Unreachable => {},

            // OpUndef is folded to a zero literal in collectNames; emit nothing here.
            .Undef => {},

            // Nop
            .Nop => {},

            // All/Any (vector boolean reduction)
            .All => try emitCall(module, names, inst, "all", w, arena, indent),
            .Any => try emitCall(module, names, inst, "any", w, arena, indent),

            // IsInf/IsNan — WGSL has NO isInf/isNan builtins (zioshade previously
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
            .CompositeInsert => try emitCompositeInsertWgsl(module, names, inst, w, arena, indent),

            // VectorExtractDynamic
            .VectorExtractDynamic => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const vector = names.get(inst.words[3]) orelse "vec";
                const index = names.get(inst.words[4]) orelse "i";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s}[{s}];\n", .{ result_name, rt, vector, index });
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
                // Wrap to the query's OWN result signedness: glslang declares ivecN
                // (signed wrap), naga declares uvecN (unsigned wrap, where
                // textureNumLayers is already u32 and needs no i32() cast).
                // (#wgsl-cts)
                const unsigned_result = intTypeIsUnsigned(module, inst.words[1]);
                const wrap = intVecTypeFor(shape.spatial, !unsigned_result);
                const layers: []const u8 = if (unsigned_result)
                    try std.fmt.allocPrint(arena, "textureNumLayers({s})", .{image})
                else
                    try std.fmt.allocPrint(arena, "i32(textureNumLayers({s}))", .{image});
                try writeInd(w, indent);
                if (shape.arrayed) {
                    try w.print("let {s}: {s} = {s}({s}(textureDimensions({s})), {s});\n", .{ result_name, rt, rt, wrap, image, layers });
                } else {
                    try w.print("let {s}: {s} = {s}(textureDimensions({s}));\n", .{ result_name, rt, rt, image });
                }
            },

            // ImageQuerySizeLod — see ImageQuerySize: convert unsigned dims to the
            // query's own result signedness, appending textureNumLayers for arrayed
            // samplers. (textureNumLayers takes NO lod argument.) A STORAGE image
            // is single-mip: WGSL's textureDimensions has no level overload for
            // storage textures, so the lod operand is dropped. (#wgsl-cts)
            .ImageQuerySizeLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                const lod = names.get(inst.words[4]) orelse "0";
                const shape = imageQueryShape(module, inst.words[3]);
                const unsigned_result = intTypeIsUnsigned(module, inst.words[1]);
                const wrap = intVecTypeFor(shape.spatial, !unsigned_result);
                const layers: []const u8 = if (unsigned_result)
                    try std.fmt.allocPrint(arena, "textureNumLayers({s})", .{image})
                else
                    try std.fmt.allocPrint(arena, "i32(textureNumLayers({s}))", .{image});
                const dims: []const u8 = if (shape.storage)
                    try std.fmt.allocPrint(arena, "textureDimensions({s})", .{image})
                else
                    try std.fmt.allocPrint(arena, "textureDimensions({s}, {s})", .{ image, lod });
                try writeInd(w, indent);
                if (shape.arrayed) {
                    try w.print("let {s}: {s} = {s}({s}({s}), {s});\n", .{ result_name, rt, rt, wrap, dims, layers });
                } else {
                    try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, dims });
                }
            },

            // ImageQueryLevels — WGSL textureNumLevels returns UNSIGNED (u32),
            // but GLSL textureQueryLevels is a SIGNED `int`, so zioshade's result
            // type (`rt`) is i32; emit `i32(textureNumLevels(t))` to convert
            // (matching the ImageQuerySize/textureDimensions wrap above). A bare
            // builtin would leave `let v: i32 = textureNumLevels(t)` → naga reject.
            .ImageQueryLevels => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s}(textureNumLevels({s}));\n", .{ result_name, rt, rt, image });
            },

            // ImageQuerySamples — WGSL textureNumSamples returns UNSIGNED (u32);
            // GLSL textureSamples is signed `int`. Convert like ImageQueryLevels.
            .ImageQuerySamples => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s}(textureNumSamples({s}));\n", .{ result_name, rt, rt, image });
            },

            // ImageQueryLod (GLSL textureQueryLod) — WGSL has NO equivalent
            // (no textureQueryLod builtin). zioshade previously emitted
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
                // The sampler must be the call-site one when the OpSampledImage was
                // built from separate texture+sampler (naga's only shape): for a
                // DEPTH texture gathered WITHOUT a Dref, the implicit
                // `<tex>_sampler` partner is declared sampler_comparison and naga
                // rejects the pairing ("Comparison sampling mismatch ... reference
                // was provided=false"). For the combined-sampler fallback there is
                // no plain partner at all, so honest-error on depth. (#wgsl-cts)
                var sampler_arg: []const u8 = try std.fmt.allocPrint(arena, "{s}_sampler", .{tex_name});
                var has_call_site_sampler = false;
                if (si_inst) |sii| {
                    if (sii.op == .SampledImage and sii.words.len > 4) {
                        if (names.get(sii.words[4])) |sn| {
                            sampler_arg = sn;
                            has_call_site_sampler = true;
                        }
                    }
                }
                if (shape.depth and !has_call_site_sampler) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL depth-texture gather without Dref needs a plain (non-comparison) sampler; the combined-sampler form has none", .{}) catch null;
                    return error.UnsupportedImageOperands;
                }
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureGather({s}, {s}, {s}, {s}{s}, i32(round({s}{s})){s});\n", .{ result_name, rt, component, tex_name, sampler_arg, coord, cs, coord, ls, offset_suffix });
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureGather({s}, {s}, {s}, {s}{s});\n", .{ result_name, rt, component, tex_name, sampler_arg, coord, offset_suffix });
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
                // The sampler argument: a call-site OpSampledImage carries the
                // real separate comparison sampler (resolveSamplerArg); a
                // combined sampler2DShadow falls back to the `<tex>_sampler`
                // partner (declared sampler_comparison for depth textures).
                const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
                const shape = depthCompareShape(module, inst.words[3]);
                // ConstOffset (image-operand bit 0x8; Dref=words[5], mask=words[6],
                // operand words[7]). WGSL textureGatherCompare's const-offset arg
                // exists for texture_depth_2d AND texture_depth_2d_array (both
                // arrayed and non-arrayed forms), but NOT for cube/cube_array ->
                // honest-error on cube. Dropping the offset gathers the WRONG
                // texels (naga accepts the shorter call: silent-wrong). A gather
                // admits no other operand (Bias/Lod/Grad are invalid on
                // OpImageDrefGather anyway); anything else in the mask is
                // honest-errored rather than mis-skipped.
                var off_suffix: []const u8 = "";
                const gmask: u32 = if (inst.words.len > 6) inst.words[6] else 0;
                if (gmask & ~@as(u32, 0x8) != 0) return error.UnsupportedImageOperands;
                if (gmask & 0x8 != 0) {
                    if (shape.comps == 3) return error.UnsupportedImageOperands;
                    if (inst.words.len < 8) return error.UnsupportedImageOperands;
                    off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[7]) orelse "vec2<i32>(0)"});
                }
                // On an ARRAYED depth texture WGSL takes the layer as a SEPARATE
                // rounded i32 array_index argument between the coordinate and the
                // depth-ref: textureGatherCompare(t, s, coord.<spatial>,
                // i32(round(coord.<layer>)), dref). glslang packs the layer into the
                // coordinate (uv,layer for 2d_array; xyz,layer for cube_array), so it
                // must be sliced out — matching the compare-SAMPLE path in
                // emitDepthCompare. (Was previously an honest error, #170.)
                if (shape.arrayed) {
                    const cs = arrayedCoordSwizzle(shape.comps);
                    const ls = arrayedLayerSwizzle(shape.comps);
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureGatherCompare({s}, {s}, {s}{s}, i32(round({s}{s})), {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, cs, coord, ls, dref, off_suffix });
                } else {
                    try writeInd(w, indent);
                    try w.print("let {s}: {s} = textureGatherCompare({s}, {s}, {s}, {s}{s});\n", .{ result_name, rt, tex_name, sampler_arg, coord, dref, off_suffix });
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
                // Integer textures are non-filterable in WGSL — projective sampling
                // of an isampler/usampler is the same silent-wrong as the plain
                // sample arms (textureLoad only; no faithful proj form). (#170)
                if (isIntegerSampledImage(module, inst.words[3])) return error.UnsupportedIntegerTextureSample;
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
                    // The explicit-LOD proj op carries EITHER a Lod (textureProjLod)
                    // OR a Grad (textureProjGrad) image operand — branch on the mask
                    // (words[5]) rather than assuming Lod. The gradients are explicit
                    // screen-space derivatives, used as-is with the divided coord
                    // (matches glslang, which passes them through unchanged).
                    const mask = if (inst.words.len > 5) inst.words[5] else 0;
                    if (mask & 0x4 != 0) {
                        // Grad: dPdx = words[6], dPdy = words[7].
                        if (inst.words.len <= 7) return error.UnsupportedImageOperands;
                        const ddx = names.get(inst.words[6]) orelse "0";
                        const ddy = names.get(inst.words[7]) orelse "0";
                        if (mask & 0x8 != 0) {
                            // Grad|ConstOffset (textureProjGradOffset): the const offset
                            // follows BOTH gradients. WGSL textureSampleGrad takes a
                            // trailing const-offset arg; dropping it = silent-wrong.
                            if (inst.words.len <= 8) return error.UnsupportedImageOperands;
                            const off = names.get(inst.words[8]) orelse "vec2<i32>(0)";
                            try w.print("let {s}: {s} = textureSampleGrad({s}, {s}_sampler, {s}{s} / {s}{s}, {s}, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, ddx, ddy, off });
                        } else {
                            try w.print("let {s}: {s} = textureSampleGrad({s}, {s}_sampler, {s}{s} / {s}{s}, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, ddx, ddy });
                        }
                    } else {
                        const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                        if (mask & 0x8 != 0) {
                            // Lod|ConstOffset (textureProjLodOffset): the const offset
                            // follows the lod. WGSL textureSampleLevel takes a trailing
                            // const-offset arg; dropping it would silently ignore it.
                            if (inst.words.len <= 7) return error.UnsupportedImageOperands;
                            const off = names.get(inst.words[7]) orelse "vec2<i32>(0)";
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}{s} / {s}{s}, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, lod, off });
                        } else {
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}{s} / {s}{s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, lod });
                        }
                    }
                } else {
                    // ImageSampleProjImplicitLod. textureProjOffset carries a ConstOffset
                    // image operand (mask 0x8 at words[5], offset at words[6]); WGSL
                    // textureSample takes a trailing const-offset arg. Dropping it would
                    // silently sample the un-offset texels.
                    const mask = if (inst.words.len > 5) inst.words[5] else 0;
                    // #wgsl-uniformity-8k2: in non-uniform flow the gated
                    // textureSample becomes textureSampleLevel with the level
                    // pinned to 0 (same lowering as the non-projective path; a
                    // projective Bias has no uniformity-safe WGSL form either
                    // and is dropped like the Bias operand there).
                    const proj_nonuniform = nonuniform_gated.contains(inst.words[2]);
                    if (mask & 0x8 != 0) {
                        if (inst.words.len <= 6) return error.UnsupportedImageOperands;
                        const off = names.get(inst.words[6]) orelse "vec2<i32>(0)";
                        if (proj_nonuniform) {
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}{s} / {s}{s}, 0.0, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, off });
                        } else {
                            try w.print("let {s}: {s} = textureSample({s}, {s}_sampler, {s}{s} / {s}{s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp, off });
                        }
                    } else {
                        if (proj_nonuniform) {
                            try w.print("let {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}{s} / {s}{s}, 0.0);\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp });
                        } else {
                            try w.print("let {s}: {s} = textureSample({s}, {s}_sampler, {s}{s} / {s}{s});\n", .{ result_name, rt, tex_name, tex_name, coord, lead, coord, last_comp });
                        }
                    }
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
                var tex_name: []const u8 = names.get(inst.words[3]) orelse "tex";
                if (getDef(module, inst.words[3])) |sii| {
                    if (sii.op == .SampledImage and sii.words.len > 3) {
                        tex_name = names.get(sii.words[2]) orelse tex_name;
                    }
                }
                const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
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
                // ConstOffset (0x8): the projective depth-2d form keeps WGSL's
                // textureSampleCompare offset arg. Dref=words[5], mask=words[6].
                // A Bias (0x1) or Lod (0x2) has no faithful projective-compare
                // form (WGSL depth-compare builtins carry neither), so anything
                // beyond ConstOffset in the mask honest-errors instead of being
                // silently skipped. (#170)
                var off_suffix: []const u8 = "";
                {
                    const pmask: u32 = if (inst.words.len > 6) inst.words[6] else 0;
                    if (pmask & ~@as(u32, 0x8) != 0) return error.UnsupportedImageOperands;
                    if (pmask & 0x8 != 0) {
                        if (inst.words.len < 8) return error.UnsupportedImageOperands;
                        off_suffix = try std.fmt.allocPrint(arena, ", {s}", .{names.get(inst.words[7]) orelse "vec2<i32>(0)"});
                    }
                }
                try writeInd(w, indent);
                // #wgsl-uniformity-8k2: textureSampleCompare is uniformity-gated;
                // for the IMPLICIT variant in non-uniform flow use the ungated
                // textureSampleCompareLevel (same arguments; samples mip 0).
                // The EXPLICIT variant takes that form UNCONDITIONALLY: its
                // SPIR-V Lod is dropped just above (WGSL has no projective
                // compare-with-LOD builtin), so the level-pinned builtin is the
                // faithful spelling exactly as on the non-proj
                // ImageSampleDrefExplicitLod path -- and the prepass only ever
                // records the four *ImplicitLod opcodes among the SAMPLES (its
                // other entries are derivative result ids, which no sample arm
                // can consult), so consulting it here could never have marked
                // an Explicit sample and this arm was emitting the gated
                // builtin for every one of them.
                const cmp_builtin: []const u8 = if (inst.op == .ImageSampleProjDrefExplicitLod or nonuniform_gated.contains(inst.words[2]))
                    "textureSampleCompareLevel"
                else
                    "textureSampleCompare";
                try w.print("let {s}: {s} = {s}({s}, {s}, {s}{s} / {s}{s}, {s} / {s}{s}{s});\n", .{ result_name, rt, cmp_builtin, tex_name, sampler_arg, coord, lead, coord, last_comp, dref, coord, last_comp, off_suffix });
            },

            // ReadClockKHR — shader clock
            .ReadClockKHR => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                try writeInd(w, indent);
                try w.print("let {s}: {s} = 0u; // ReadClockKHR stub\n", .{ result_name, rt });
            },

            // ImageRead (storage image load)
            .ImageRead => {
                const shape = storageImageShape(module, inst.words[3]);
                if (shape.ms) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no multisampled storage texture (image2DMS imageLoad)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "img";
                // SubpassData (SPIR-V Dim 6 = Vulkan input attachments): the SPIR-V
                // coordinate operand is a (0,0) placeholder, because Vulkan reads a
                // subpass attachment implicitly at the current fragment position. WGSL
                // has no implicit subpass read, so emit the threaded fragment
                // coordinate (a @builtin(position) name) instead of passing (0,0)
                // through verbatim -- otherwise every fragment samples the top-left
                // pixel. (Port of the MSL #488 fix; MS subpass is honest-errored
                // above by the shape.ms guard.) `subpass_fragcoord_name` is threaded
                // from the top level, which synthesizes a @builtin(position) input
                // when the source SPIR-V lacks gl_FragCoord (subpassLoad never names
                // it); null means this is not a fragment shader with a subpass read.
                const is_subpass = imageValueDim(module, inst.words[3]) == 6;
                if (is_subpass and subpass_fragcoord_name == null) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "SubpassData OpImageRead needs the fragment coordinate, but none is available (not a fragment shader?)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                try writeInd(w, indent);
                if (is_subpass) {
                    try w.print("let {s}: {s} = textureLoad({s}, vec2<i32>({s}.xy));\n", .{ result_name, rt, image, subpass_fragcoord_name.? });
                } else if (shape.arrayed) {
                    // WGSL takes the array layer as a SEPARATE arg: textureLoad(t, coord.xy, coord.z).
                    const coord = names.get(inst.words[4]) orelse "uv";
                    const spat: []const u8 = if (shape.spatial == 1) ".x" else ".xy";
                    const layer: []const u8 = if (shape.spatial == 1) ".y" else ".z";
                    try w.print("let {s}: {s} = textureLoad({s}, ({s}){s}, ({s}){s});\n", .{ result_name, rt, image, coord, spat, coord, layer });
                } else {
                    const coord = names.get(inst.words[4]) orelse "uv";
                    try w.print("let {s}: {s} = textureLoad({s}, {s});\n", .{ result_name, rt, image, coord });
                }
            },

            // ImageWrite (storage image store)
            .ImageWrite => {
                const shape = storageImageShape(module, inst.words[1]);
                if (shape.ms) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no multisampled storage texture (image2DMS imageStore)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const image = names.get(inst.words[1]) orelse "img";
                const coord = names.get(inst.words[2]) orelse "uv";
                const texel = names.get(inst.words[3]) orelse "color";
                try writeInd(w, indent);
                if (shape.arrayed) {
                    const spat: []const u8 = if (shape.spatial == 1) ".x" else ".xy";
                    const layer: []const u8 = if (shape.spatial == 1) ".y" else ".z";
                    try w.print("textureStore({s}, ({s}){s}, ({s}){s}, {s});\n", .{ image, coord, spat, coord, layer, texel });
                } else {
                    try w.print("textureStore({s}, {s}, {s});\n", .{ image, coord, texel });
                }
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
                try writeInd(w, indent);
                try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, val });
            },

            // CopyMemory
            .CopyMemory => {
                if (inst.words.len >= 3) {
                    const dst = names.get(inst.words[1]) orelse "dst";
                    const src = names.get(inst.words[2]) orelse "src";
                    try writeInd(w, indent);
                    try w.print("{s} = {s};\n", .{ dst, src });
                }
            },

            // ArrayLength — runtime SSBO array `.length()`. WGSL: arrayLength(&buf.member),
            // returning u32 (matching the uint result type). words[3]=struct (block-var)
            // pointer, words[4]=runtime-array member index. (#294)
            .ArrayLength => {
                if (inst.words.len < 5) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: malformed OpArrayLength (needs >= 5 words)", .{}) catch null;
                    return error.UnsupportedOp;
                }
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
                if (struct_id == 0) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: OpArrayLength needs a runtime-array struct member", .{}) catch null;
                    return error.UnsupportedOp;
                }
                var mbuf: [32]u8 = undefined;
                const member_name = getMemberName(module, struct_id, member_idx, &mbuf);
                try writeInd(w, indent);
                try w.print("let {s}: {s} = arrayLength(&{s}.{s});\n", .{ result_name, rt, buf_name, member_name });
            },

            // ControlBarrier / MemoryBarrier.
            // #475: OpControlBarrier commonly carries UniformMemory semantics (SSBO
            // writes). workgroupBarrier() fences ONLY workgroup memory (+ execution
            // sync) — an SSBO write before the barrier would NOT be visible after,
            // silently. Also emit storageBarrier() (the conservative both-fence GLSL
            // uses via barrier()+memoryBarrier()) so storage writes are visible.
            // Over-fencing is safe (a no-op when there's no storage access).
            .ControlBarrier => {
                // WGSL workgroupBarrier()/storageBarrier() are COMPUTE-stage only. In a
                // fragment/vertex entry point they are forbidden (naga rejects), and a
                // control barrier there is a semantic no-op (no cross-invocation sync) --
                // omit. (#wgsl-barrier-stage)
                if (module.execution_model == .GLCompute) {
                    try writeInd(w, indent);
                    try w.writeAll("workgroupBarrier();\n");
                    try writeInd(w, indent);
                    try w.writeAll("storageBarrier();\n");
                }
            },
            .MemoryBarrier => {
                if (module.execution_model == .GLCompute) {
                    try writeInd(w, indent);
                    try w.writeAll("storageBarrier();\n");
                }
                // else: storageBarrier is compute-only; a fragment/vertex memory barrier is a no-op.
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
            // OpAtomicStore: WGSL atomicStore(&p, v). Unlike the RMW atomics this
            // op has NO result type/id, so its operand layout is shifted one word
            // earlier: [1]=pointer [2]=scope [3]=semantics [4]=value. WGSL atomics
            // are RELAXED: Acquire/Release/AcquireRelease/SequentiallyConsistent
            // semantics bits have NO faithful WGSL form, so honest-error rather
            // than emit a weaker store than the source ordered.
            .AtomicStore => {
                if (inst.words.len < 5) return error.UnsupportedOp;
                if (atomicPtrIsImage(module, names, inst.words[1])) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no image atomic operations (atomicStore on a storage image)", .{}) catch null;
                    return error.UnsupportedOp;
                }
                // The semantics operand is an ID of a u32 OpConstant, not a literal.
                const semantics: u32 = if (getDef(module, inst.words[3])) |sc_i| blk: {
                    if (sc_i.op != .Constant or sc_i.words.len < 4) break :blk std.math.maxInt(u32);
                    break :blk sc_i.words[3];
                } else std.math.maxInt(u32);
                if (semantics & (0x2 | 0x4 | 0x8 | 0x10) != 0) {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL atomicStore is relaxed; OpAtomicStore with acquire/release/sequentially-consistent semantics has no faithful WGSL form", .{}) catch null;
                    return error.UnsupportedOp;
                }
                const ptr = names.get(inst.words[1]) orelse "ptr";
                const val = names.get(inst.words[4]) orelse "0";
                try writeInd(w, indent);
                try w.print("atomicStore(&{s}, {s});\n", .{ ptr, val });
            },
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
                try writeInd(w, indent);
                try w.print("let {s}: {s} = atomicExchange(&{s}, {s});\n", .{ rn, rt, ptr, val });
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
                try writeInd(w, indent);
                try w.print("let {s}: {s} = atomicCompareExchangeWeak(&{s}, {s}, {s}).old_value;\n", .{ rn, rt, ptr, cmp, val });
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
                // `select`). The `ctx.dead_extracts`/inline pre-scans are guarded so the
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
    const mt = getDef(module, inst.words[1]) orelse {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: matrix-from-vector result type {d} unresolved", .{inst.words[1]}) catch null;
        return error.UnsupportedOp;
    };
    if (mt.op != .TypeMatrix or mt.words.len < 4) {
        last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL: matrix-from-vector expected a TypeMatrix result", .{}) catch null;
        return error.UnsupportedOp;
    }
    const cols = mt.words[3];
    var buf = std.ArrayList(u8).initCapacity(arena, 96) catch return error.OutOfMemory;
    defer buf.deinit(arena);
    try compat.listWriter(&buf, arena).print("{s}(", .{rt});
    var i: u32 = 0;
    while (i < cols) : (i += 1) {
        if (i > 0) try buf.appendSlice(arena, ", ");
        // v[i] selected via swizzle for a vector (x/y/z/w).
        try compat.listWriter(&buf, arena).print("{s} * {s}.{s}", .{ u, v, common.swizzleChar(i) });
    }
    try buf.appendSlice(arena, ")");
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, buf.items });
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

/// Returns the value of a scalar integer OpConstant, else null. zioshade lowers
/// every integer type to a 32-bit i32/u32 in WGSL, so the value lives in
/// words[3] (a 64-bit constant would also use words[4], but those are
/// honest-errored in the frontend before reaching this backend).
fn constIntValue(module: *const ParsedModule, id: u32) ?u32 {
    const ci = common.getDef(module, id) orelse return null;
    if (ci.op != .Constant or ci.words.len < 4) return null;
    const ti = common.getDef(module, ci.words[1]) orelse return null;
    if (ti.op != .TypeInt) return null;
    return ci.words[3];
}

fn isConstantZero(module: *const ParsedModule, id: u32) bool {
    const ci = common.getDef(module, id) orelse return false;
    // The literal word for a scalar int 0 / float +0.0 is the all-zero bit pattern.
    // Limitation: a 64-bit integer constant `0x1_00000000` also has words[3]==0; this
    // would false-positive, but zioshade honest-errors 64-bit integer types in the
    // frontend (semantic.zig) before they reach the WGSL backend, so it is unreachable
    // for zioshade's own output (and a false honest-error is preferable to silent-wrong
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
    // #258: an INTEGER division/remainder whose DIVISOR is a const-expression zero.
    // Per the WGSL spec this is a shader-creation error whenever the divisor is a
    // const-expression evaluating to 0 -- REGARDLESS of whether the dividend is a
    // constant or a runtime value (naga 0.30 rejects both `4 / 0` and `b / 0` with
    // "Division by zero"). WGSL has no integer inf/nan, so the result is
    // unrepresentable either way; honest-error rather than emit naga-invalid WGSL.
    // (The old band-aid emitted `0.0`, itself naga-invalid for an integer result;
    // an earlier revision emitted a bare `b / 0`, which naga also rejects.) The float
    // const/const case was already folded to a non-finite bitcast above (#254), and a
    // runtime float `x / 0.0` is a legitimate runtime inf, so this guard is
    // integer-only.
    if (inst.words.len >= 5 and
        (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) and
        isConstantZero(module, inst.words[4]) and
        isIntegerType(module, inst.words[1]))
    {
        last_error_detail = std.fmt.bufPrint(
            &last_error_detail_buf,
            "integer division by a constant zero has no WGSL representation",
            .{},
        ) catch null;
        return error.UnsupportedOp;
    }
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    // Wrap compound expressions in parens for correct precedence
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op, rhs });
}

/// #170: emit an UNORDERED float comparison (OpFUnordLessThan and friends). WGSL's
/// relational operators are all ORDERED -- `a < b`, `a >= b` etc. return false when
/// either operand is NaN -- so mapping OpFUnord* straight onto `<`/`>=` (as the
/// MSL/HLSL backends and spirv-cross do) is plausible-but-wrong on a NaN operand:
/// the unordered form must return TRUE there. Rather than emit that silent-wrong
/// output we lower each unordered inequality to the logical negation of its
/// COMPLEMENTARY ordered comparison, which is exact by the IEEE-754 / SPIR-V
/// definition (unordered-OP == !ordered-complement, because the ordered complement
/// is itself already false whenever the operands are unordered):
///   FUnordLessThan(a,b)         == !(a >= b)   (complement FOrdGreaterThanEqual)
///   FUnordGreaterThan(a,b)      == !(a <= b)   (complement FOrdLessThanEqual)
///   FUnordLessThanEqual(a,b)    == !(a > b)    (complement FOrdGreaterThan)
///   FUnordGreaterThanEqual(a,b) == !(a < b)    (complement FOrdLessThan)
/// WGSL `!` is componentwise on vecN<bool>, so this is uniform for scalar and vector
/// results with no typed constant. (OpFUnordEqual is the one unordered comparison that
/// does NOT fit this negate-a-complement shape -- its complement OpFOrdNotEqual has no
/// single WGSL operator -- so it is handled separately by emitUnorderedEqual.) These ops
/// are kept out of every inline/symbol table on purpose, so they always materialize
/// through this emitter and can never be re-derived as a bare (wrong) `lhs op rhs`.
fn emitUnorderedCompare(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, complement_op: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = !({s} {s} {s});\n", .{ result_name, rt, lhs, complement_op, rhs });
}

/// #170: emit OpFUnordEqual, the unordered float equality. It is TRUE when the operands
/// are equal OR either is NaN, so -- like the unordered inequalities -- mapping it onto
/// a naive `==` (ordered, false on NaN, as MSL/HLSL/spirv-cross do) is plausible-but-wrong
/// on a NaN operand. Unlike the inequalities it has no single-operator ordered complement
/// (`FOrdNotEqual` is not a WGSL operator), so it is lowered directly from the IEEE-754 /
/// SPIR-V definition:
///   FUnordEqual(a,b) == (a == b) || isNaN(a) || isNaN(b),   isNaN(x) == (x != x)
/// WGSL has no `||` on vecN<bool> (it is scalar-bool short-circuit only) and no bool
/// vector constant is available without knowing the width, so the OR is composed with
/// `select`: OR(P,Q) == `select(Q, P, P)` (P true -> true; else Q), which is uniform for
/// scalar and vecN<bool>. Nesting it twice gives (a==b) OR (isNaN(a) OR isNaN(b)). Kept
/// out of every inline/symbol table (like emitUnorderedCompare) so it always materializes
/// here and is never re-derived as a bare `==`.
fn emitUnorderedEqual(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent);
    // select(isNaN(a)||isNaN(b), a==b, a==b) where the inner select is isNaN(a)||isNaN(b).
    try w.print(
        "let {s}: {s} = select(select({s} != {s}, {s} != {s}, {s} != {s}), {s} == {s}, {s} == {s});\n",
        .{ result_name, rt, rhs, rhs, lhs, lhs, lhs, lhs, lhs, rhs, lhs, rhs },
    );
}

/// OpFOrdNotEqual: ordered not-equal is FALSE on a NaN operand, but WGSL `!=` follows
/// IEEE-754 (unordered = true on NaN), so bare `!=` is plausible-but-wrong for the
/// ordered form. FOrdNotEqual is the complement of FUnordEqual, so emit `!(...)` over
/// the select()-based FUnordEqual form (mirrors emitUnorderedEqual; WGSL `!` is
/// componentwise on vecN<bool>, and select() avoids &&/|| on vecN<bool>). glslang
/// never emits FOrdNotEqual. Like emitUnorderedEqual/emitUnorderedCompare, this is kept
/// out of EVERY inline/symbol table (isInlineableArithOp, getInlineBinOp,
/// buildInlineExpr, getBinOpSymbol, the condition-resolution switch) and routed through
/// this emitter in BOTH the main dispatch and the switch/loop replay path, so a
/// single-use or replayed FOrdNotEqual can NEVER be re-derived as a bare (wrong) `!=`.
fn emitOrderedNotEqual(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent);
    try w.print(
        "let {s}: {s} = !(select(select({s} != {s}, {s} != {s}, {s} != {s}), {s} == {s}, {s} == {s}));\n",
        .{ result_name, rt, rhs, rhs, lhs, lhs, lhs, lhs, lhs, rhs, lhs, rhs },
    );
}

/// OpFMod takes the sign of operand 2 (the divisor) — GLSL mod() semantics. WGSL's
/// float `%` takes the sign of operand 1 (truncated remainder, like C fmod), so it
/// is silently wrong for operands of opposite sign. Emit the sign-correct expansion
/// x - y * floor(x / y), matching spirv-cross's mod() helper. (Integer OpUMod /
/// OpSMod / OpSRem keep `%`.) The non-finite constant fold is preserved so a
/// `mod(1.0, 0.0)` still folds to a NaN bitcast rather than a naga-rejected literal.
fn emitFMod(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    if (std.mem.eql(u8, rt, "f32")) {
        if (constFoldNonFiniteFloat(module, inst)) |bits| {
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = bitcast<f32>(0x{x:0>8}u);\n", .{ result_name, rt, bits });
            return;
        }
    }
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const rhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const rhs = if (isCompoundExpr(rhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{rhs_raw}) else rhs_raw;
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s} - {s} * floor({s} / {s});\n", .{ result_name, rt, lhs, rhs, lhs, rhs });
}

/// #170: emit OpSMod (floored signed modulo, sign of the DIVISOR) as `((x % y) + y) % y`.
/// WGSL `%` is truncated (sign of the dividend = OpSRem), so it is wrong for opposite-sign
/// operands; this compound turns the truncated remainder into the floored one for every
/// sign combination (verified exhaustively via naga const_assert). Componentwise, no
/// conditional. Kept out of the inline/symbol tables so it never re-derives as a bare `%`.
fn emitSMod(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const x_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const y_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
    const x = if (isCompoundExpr(x_raw)) try std.fmt.allocPrint(arena, "({s})", .{x_raw}) else x_raw;
    const y = if (isCompoundExpr(y_raw)) try std.fmt.allocPrint(arena, "({s})", .{y_raw}) else y_raw;
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = (({s} % {s}) + {s}) % {s};\n", .{ result_name, rt, x, y, y, y });
}

/// Emit a WGSL shift (`<<` / `>>`) for any of OpShiftLeftLogical,
/// OpShiftRightLogical, OpShiftRightArithmetic. WGSL requires the shift AMOUNT to
/// be u32-typed with the SAME vector dimension as the base (`vecN<T> << vecN<u32>`;
/// a scalar `u32(...)` on a vec amount is rejected — "cannot cast a vec2<u32> to a
/// u32"), so the amount is always cast/built as `shift_cast` derived from the
/// result (= base) type. The over-shift mask is applied by shiftAmountExpr.
fn emitShift(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, op_str: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs_raw = resolveOperandExpr(module, names, inline_exprs, inst.words[3], arena, 0);
    const lhs = if (isCompoundExpr(lhs_raw)) try std.fmt.allocPrint(arena, "({s})", .{lhs_raw}) else lhs_raw;
    const shift_cast: []const u8 = if (std.mem.startsWith(u8, rt, "vec2")) "vec2<u32>" else if (std.mem.startsWith(u8, rt, "vec3")) "vec3<u32>" else if (std.mem.startsWith(u8, rt, "vec4")) "vec4<u32>" else "u32";
    const amount = try shiftAmountExpr(module, names, inline_exprs, inst.words[4], shift_cast, arena);
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op_str, amount });
}

/// Build the shift-AMOUNT expression, applying the #170 constant over-shift mask
/// (& 31). GLSL/SPIR-V leave a shift by >= the operand bit width undefined (glslang
/// emits e.g. `state >> 63u` on a 32-bit uint, rule30.frag), but WGSL makes a
/// CONSTANT over-shift a shader-creation error — naga rejects the faithful
/// translation at exit 0 (silent-wrong). Masking to the low 5 bits is a no-op for
/// in-range amounts and the same wrap hardware / the HLSL+MSL backends apply. All
/// zioshade WGSL ints are 32-bit, so the mask is always & 31. The result is always
/// cast/built as `shift_cast` (u32 / vecN<u32>) to match the base's dimension.
/// Covers: scalar constants, constant-composite VECTOR amounts (mask each
/// component — constIntValue is null for composites, so they escaped the scalar
/// mask), and runtime amounts (cast unchanged).
fn shiftAmountExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), amount_id: u32, shift_cast: []const u8, arena: std.mem.Allocator) ![]const u8 {
    // Scalar integer constant: mask an over-shift to the low 5 bits.
    if (constIntValue(module, amount_id)) |cv| {
        if (cv >= 32) return std.fmt.allocPrint(arena, "{s}({d}u)", .{ shift_cast, cv & 31 });
        const raw = resolveOperandExpr(module, names, inline_exprs, amount_id, arena, 0);
        return std.fmt.allocPrint(arena, "{s}({s})", .{ shift_cast, raw });
    }
    // Constant-composite (vector) amount: if ANY component over-shifts, rebuild the
    // amount as a masked vecN<u32> literal. Only rebuild when needed, so an in-range
    // composite keeps its original emission.
    if (common.getDef(module, amount_id)) |ci| {
        if (ci.op == .ConstantComposite and ci.words.len > 3) {
            const comps = ci.words[3..];
            var all_const = true;
            var any_over = false;
            for (comps) |cid| {
                if (constIntValue(module, cid)) |cv| {
                    if (cv >= 32) any_over = true;
                } else {
                    all_const = false;
                    break;
                }
            }
            if (all_const and any_over) {
                var buf = try std.ArrayList(u8).initCapacity(arena, 64);
                try buf.print(arena, "{s}(", .{shift_cast});
                for (comps, 0..) |cid, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try buf.print(arena, "{d}u", .{constIntValue(module, cid).? & 31});
                }
                try buf.appendSlice(arena, ")");
                return buf.toOwnedSlice(arena);
            }
        }
    }
    // Runtime amount (or in-range composite): cast unchanged to the base's dimension.
    const raw = resolveOperandExpr(module, names, inline_exprs, amount_id, arena, 0);
    return std.fmt.allocPrint(arena, "{s}({s})", .{ shift_cast, raw });
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
                        const op_pair = s[i + 1 .. i + 3];
                        if (std.mem.eql(u8, op_pair, "<=") or std.mem.eql(u8, op_pair, ">=") or
                            std.mem.eql(u8, op_pair, "==") or std.mem.eql(u8, op_pair, "!=") or
                            std.mem.eql(u8, op_pair, "<<") or std.mem.eql(u8, op_pair, ">>"))
                        {
                            return true;
                        }
                    }
                    // "or" and "and" keywords
                    if (i + 3 < s.len and s[i + 3] == ' ') {
                        const kw = s[i + 1 .. i + 3];
                        if (std.mem.eql(u8, kw, "or")) return true;
                    }
                    if (i + 4 < s.len and s[i + 4] == ' ') {
                        const kw = s[i + 1 .. i + 4];
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
            // Single-store private forwarding: a forwarded load reads the one
            // dominating store's value and the variable has no declaration
            // left, so the pointer's name must NOT win here (it would emit an
            // undeclared identifier).
            if (def.op == .Load) {
                if (forward_private_stores.get(def.words[3])) |fwd| {
                    if (names.get(fwd)) |vn| return vn;
                }
            }
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
        .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual, .FOrdEqual, .FUnordNotEqual, .SLessThan, .SGreaterThan, .SLessThanEqual, .SGreaterThanEqual, .ULessThan, .UGreaterThan, .ULessThanEqual, .UGreaterThanEqual, .IEqual, .INotEqual => {
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
            // Single-store private forwarding (see resolveSourceName's twin):
            // the load resolves to the stored value, not the var's name.
            if (cond_def.op == .Load) {
                if (forward_private_stores.get(cond_def.words[3])) |fwd| {
                    if (names.get(fwd)) |vn| return vn;
                }
            }
            return inlineConditionExpr(module, names, cond_def.words[3], arena, depth + 1);
        },
        else => return null,
    }
}

// Emit a single instruction — used for replaying deferred loop header instructions
// #post-loop-header-use: writer wrapper that buffers every write into `pending`
// so the statement(s) a single instruction produced can be rewritten in place
// before they reach the real writer. The emit loop flushes at the top of every
// instruction, so `pending` always holds exactly what was emitted since the
// last flush - normally the previous instruction's statements.
fn HoistWriter(comptime W: type) type {
    return struct {
        real: W,
        pending: *std.ArrayList(u8),
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
            return self.pending.print(self.alloc, fmt, args);
        }

        pub fn writeAll(self: Self, data: []const u8) !void {
            return self.pending.appendSlice(self.alloc, data);
        }

        pub fn flush(self: Self) !void {
            if (self.pending.items.len == 0) return;
            try self.real.writeAll(self.pending.items);
            self.pending.clearRetainingCapacity();
        }
    };
}

const PendingHoist = enum { rewrote, absent, unrecognized };

/// True when everything between `line_start` and `kw_pos` is indentation.
fn lineStartsStatement(text: []const u8, line_start: usize, kw_pos: usize) bool {
    for (text[line_start..kw_pos]) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return true;
}

/// #post-loop-header-use: rewrite the buffered definition of a hoisted value
/// from a declaration into an assignment so it stores into the `var name: T;`
/// declared above the loop instead of shadowing it (a shadowing declaration
/// would leave every post-loop read at the var's zero value: silent-wrong):
///   `<indent>let name: T = expr;`  ->  `<indent>name = expr;`
///   `<indent>var name: T = expr;`  ->  `<indent>name = expr;`  (emitCall,
///                                     CompositeInsert write mutable locals)
///   `<indent>var name: T;`         ->  line dropped (Select struct/array lowers
///                                     to var + guarded assignments; the guards
///                                     then target the hoisted var)
/// Returns `absent` when no declaration for `name` is in the buffer (its
/// definition has not been emitted yet, or emitted nothing), `unrecognized`
/// when a declaration line exists but matches none of these shapes. The
/// keyword must sit at a line start (indentation only before it) so a
/// same-named identifier inside an expression can never be mistaken for the
/// declaration.
fn rewritePendingHoist(pending: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8) !PendingHoist {
    var nbuf: [96]u8 = undefined;
    var vbuf: [96]u8 = undefined;
    const let_needle = std.fmt.bufPrint(&nbuf, "let {s}: ", .{name}) catch return .absent;
    const var_needle = std.fmt.bufPrint(&vbuf, "var {s}: ", .{name}) catch return .absent;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, pending.items, from, let_needle)) |pos| {
        const ls = if (std.mem.lastIndexOfScalar(u8, pending.items[0..pos], '\n')) |nl| nl + 1 else 0;
        if (lineStartsStatement(pending.items, ls, pos)) {
            const ty_start = pos + let_needle.len;
            const eq = std.mem.indexOfPos(u8, pending.items, ty_start, " = ") orelse return .unrecognized;
            if (std.mem.indexOfScalar(u8, pending.items[ty_start..eq], ';') != null) return .unrecognized;
            // Strike out `let name: T`, keeping the name: [0..pos) + name + [eq..).
            try pending.replaceRange(alloc, pos, eq - pos, name);
            return .rewrote;
        }
        from = pos + 1;
    }
    from = 0;
    while (std.mem.indexOfPos(u8, pending.items, from, var_needle)) |pos| {
        const ls = if (std.mem.lastIndexOfScalar(u8, pending.items[0..pos], '\n')) |nl| nl + 1 else 0;
        if (lineStartsStatement(pending.items, ls, pos)) {
            const ty_start = pos + var_needle.len;
            const eq = std.mem.indexOfPos(u8, pending.items, ty_start, " = ");
            if (eq) |e| {
                if (std.mem.indexOfScalar(u8, pending.items[ty_start..e], ';') != null) return .unrecognized;
                try pending.replaceRange(alloc, pos, e - pos, name);
                return .rewrote;
            }
            const semi = std.mem.indexOfScalarPos(u8, pending.items, ty_start, ';') orelse return .unrecognized;
            const line_end = std.mem.indexOfScalarPos(u8, pending.items, semi, '\n') orelse pending.items.len;
            if (std.mem.indexOfScalar(u8, pending.items[ty_start..semi], '=') != null) return .unrecognized;
            // Declaration-only line: drop it; later guarded assignments target the
            // hoisted var.
            const drop_end = if (line_end < pending.items.len) line_end + 1 else line_end;
            try pending.replaceRange(alloc, ls, drop_end - ls, "");
            return .rewrote;
        }
        from = pos + 1;
    }
    return .absent;
}

/// #post-loop-header-use: rewrite every hoisted definition in the pending
/// buffer, then commit it to the real writer. Sweeping the whole hoist set
/// (instead of tracking which instruction was just emitted) covers every
/// emission path at once: the main walk, the deferred header replay, and the
/// switch/short-circuit case replays all write through the same pending
/// buffer within one walk iteration. Honest-errors on an unrecognized shape -
/// a declaration we cannot safely split must not be left shadowing the
/// hoisted var.
fn hoistSweepAndFlush(pending: *std.ArrayList(u8), alloc: std.mem.Allocator, hoisted: *const std.AutoHashMap(u32, void), names: *const std.AutoHashMap(u32, []const u8), real: anytype) !void {
    if (pending.items.len > 0 and hoisted.count() > 0) {
        var it = hoisted.iterator();
        while (it.next()) |entry| {
            const hname = names.get(entry.key_ptr.*) orelse continue;
            switch (try rewritePendingHoist(pending, alloc, hname)) {
                .rewrote, .absent => {},
                .unrecognized => {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL post-loop header-value hoist cannot rewrite the loop-body definition of {s} (unrecognized emit shape)", .{hname}) catch null;
                    return error.UnsupportedOp;
                },
            }
        }
    }
    if (pending.items.len == 0) return;
    try real.writeAll(pending.items);
    pending.clearRetainingCapacity();
}

/// #wrap-backedge: emit a loop's carried-phi updates at the point where a
/// BranchConditional back-edge was lowered to `if (...) { break; }`. A continue
/// block that ends in a BranchConditional back-edge (increment, then
/// `OpBranchConditional %cond %header %merge`) gets no `continuing {}` block
/// (the continue scan requires a plain OpBranch terminator) and its back-edge is
/// a BranchConditional, which the .Branch back-edge handler never sees - so the
/// phi updates were silently DROPPED: the counter never advanced and the loop
/// could only ever exit through a mid-body break (silent-wrong; visible on
/// graphicsfuzz_059, whose `%88+1` increment never reached `%88`, also leaving
/// the phi promotable to a `let` that naga const-folds into an invalid negative
/// array index). After the break test the fall-through IS the back edge, so the
/// updates belong at the loop bottom. Gated on the other arm targeting this
/// loop's header (directly or via a pure trampoline); excludes the self-loop
/// shape (handled by the #selfloop block) and loops whose updates already live
/// in a `continuing {}` block.
fn emitWrapBackedgePhiUpdates(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    phi_updates: anytype,
    loop_stack: anytype,
    loop_header_label: ?u32,
    loop_continue_label: ?u32,
    other_target: u32,
    w: anytype,
    indent: u32,
) !void {
    if (loop_stack.items.len == 0) return;
    if (loop_header_label == null or loop_continue_label == null) return;
    if (loop_continue_label.? == loop_header_label.?) return; // self-loop: #selfloop block owns these
    if (other_target != loop_header_label.? and !isPureBranchTrampoline(module, other_target, loop_header_label.?)) return;
    const cur = &loop_stack.items[loop_stack.items.len - 1];
    if (cur.emit_continuing) return; // updates already live in `continuing {}`
    var idx: usize = cur.phi_start;
    while (idx < cur.phi_end) : (idx += 1) {
        const pu = phi_updates.items[idx];
        const rname = names.get(pu.result_id) orelse continue;
        const vname = names.get(pu.value_id) orelse continue;
        try writeIndentStatic(w, indent);
        try w.print("{s} = {s};\n", .{ rname, vname });
    }
}

/// Shared OpVectorShuffle emitter — called from BOTH the main emitBody
/// dispatch and emitSimpleInstruction (switch case-body / loop-header replay).
/// The anti-drift pattern (glslStd450WgslName rationale): the main arm carries
/// past silent-wrong fixes (the v2 concatenation-index fix below) that a
/// copy-pasted replay twin would fork. (#wgsl-replay-twin-drift)
fn emitVectorShuffleWgsl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
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
        if (idx >= v1_count) {
            single_source = false;
            break;
        }
    }
    if (single_source) {
        // All from v1 — emit as v1.xyzw swizzle
        var sw = std.ArrayList(u8).initCapacity(arena, 5) catch return;
        defer sw.deinit(arena);
        const chars = "xyzw";
        for (inst.words[5..]) |idx| {
            if (idx < 4) try sw.append(arena, chars[idx]);
        }
        try writeIndentStatic(w, indent);
        try w.print("let {s}: {s} = {s}.{s};\n", .{ result_name, rt, v1, sw.items });
    } else {
        // Mixed sources — construct from components
        try writeIndentStatic(w, indent);
        try w.print("let {s}: {s} = {s}(", .{ result_name, rt, rt });
        var first = true;
        for (inst.words[5..]) |idx| {
            if (!first) try w.writeAll(", ");
            first = false;
            const src = if (idx < v1_count) v1 else v2;
            // OpVectorShuffle selects from the CONCATENATION of v1 (indices
            // 0..v1_count-1) and v2 (indices v1_count..); a component of v2 is
            // `idx - v1_count`, NOT `idx % v1_count`. The two agree only when
            // v1 and v2 have the SAME width (the common two-vecN case), so `%`
            // silently picked the wrong v2 component whenever v2 was wider --
            // e.g. shuffle(a:vec2, b:vec4, [0,4]) is (a.x, b.z) but `%` gave
            // (a.x, b.x). v1's own components (idx < v1_count) are unaffected.
            const comp = if (idx < v1_count) idx else idx - v1_count;
            const sw = switch (comp) {
                0 => ".x",
                1 => ".y",
                2 => ".z",
                3 => ".w",
                else => ".x",
            };
            try w.print("{s}{s}", .{ src, sw });
        }
        try w.writeAll(");\n");
    }
}

/// Shared OpBitReverse emitter (reverseBits) — main dispatch and replay both
/// call this. (#wgsl-replay-twin-drift; same pure-builtin class as
/// emitBitFieldExtractWgsl.)
fn emitBitReverseWgsl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    if (inst.words.len < 4) return;
    const rt = try wgslType(module, inst.words[1], names, arena);
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = reverseBits({s});\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
}

/// Shared OpBitCount emitter — main dispatch and replay both call this. Carries
/// the signed-result constructor wrap (a past naga-invalid fix a twin would
/// fork). (#wgsl-replay-twin-drift)
fn emitBitCountWgsl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    if (inst.words.len < 4) return;
    const rt = try wgslType(module, inst.words[1], names, arena);
    // GLSL bitCount ALWAYS returns a SIGNED int (genIType), but WGSL
    // countOneBits returns the ARGUMENT's type — so an unsigned arg yields
    // u32/vecNu while the result type rt is i32/vecNi (naga: "expected
    // vec3<i32>, got vec3<u32>"). Wrap in rt(...) to match; it is an
    // identity when the argument is already signed. (Same shape as the
    // findMSB/findLSB bit-scan wrap.) (#170)
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s}(countOneBits({s}));\n", .{ names.get(inst.words[2]) orelse "v", rt, rt, names.get(inst.words[3]) orelse "0" });
}

/// Shared OpBitFieldSExtract/UExtract emitter (extractBits) — main dispatch
/// and replay both call this. (#wgsl-replay-twin-drift)
fn emitBitFieldExtractWgsl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    if (inst.words.len < 6) return;
    const rt = try wgslType(module, inst.words[1], names, arena);
    const rn = names.get(inst.words[2]) orelse "v";
    const base = names.get(inst.words[3]) orelse "0";
    const offset = names.get(inst.words[4]) orelse "0u";
    const count = names.get(inst.words[5]) orelse "0u";
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = extractBits({s}, u32({s}), u32({s}));\n", .{ rn, rt, base, offset, count });
}

/// Shared OpCompositeInsert emitter — main dispatch and replay both call
/// this. (#wgsl-replay-twin-drift)
fn emitCompositeInsertWgsl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
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
                    const sw = switch (idx) {
                        0 => ".x",
                        1 => ".y",
                        2 => ".z",
                        3 => ".w",
                        else => ".x",
                    };
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
        const sw = switch (idx) {
            0 => ".x",
            1 => ".y",
            2 => ".z",
            3 => ".w",
            else => "[0]",
        };
        try access.appendSlice(arena, sw);
    }
    // Copy the base composite into a MUTABLE local, then overwrite the
    // indexed component with the inserted object (`var`, not `let`, so
    // the member assignment is legal WGSL).
    try writeIndentStatic(w, indent);
    try w.print("var {s}: {s} = {s};\n", .{ result_name, rt, composite });
    try writeIndentStatic(w, indent);
    try w.print("{s}{s} = {s};\n", .{ result_name, access.items, object });
}

fn emitSimpleInstruction(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inline_exprs: *const std.AutoHashMap(u32, []const u8), inst: Instruction, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, indent: u32, wrapped_members: *const WrappedUniformMemberMap, matrix_outputs: *const std.AutoHashMap(u32, MatrixOutput), nonuniform_gated: *const std.AutoHashMap(u32, void)) !void {
    switch (inst.op) {
        .Variable => {
            if (inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Function or sc == .Private) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const vn = names.get(inst.words[2]) orelse "v";
                    try writeIndentStatic(w, indent);
                    try w.print("var {s}: {s};\n", .{ vn, rt });
                }
            }
        },
        .Load => {
            const result_name = names.get(inst.words[2]) orelse "v";
            const ptr = names.get(inst.words[3]) orelse "var";
            // Single-store private forwarding, replay-path twin of the main
            // emitBody arm: alias the load to the stored value's name.
            if (forward_private_stores.get(inst.words[3])) |fwd_value| {
                if (names.get(fwd_value)) |vn| {
                    if (try names.fetchPut(inst.words[2], try alloc.dupe(u8, vn))) |old| alloc.free(old.value);
                    return;
                }
            }
            // Skip inlined loads (result name == pointer name means load was inlined)
            if (!std.mem.eql(u8, result_name, ptr)) {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try writeIndentStatic(w, indent);
                try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, ptr });
            }
        },
        .Store => {
            // Dead store under single-store private forwarding (replay-path
            // twin of the main emitBody arm): no declaration to assign to.
            if (forward_private_stores.contains(inst.words[1])) return;
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
            try writeIndentStatic(w, indent);
            try w.print("{s} = {s};\n", .{ ptr, val });
        },
        // OpSampledImage in a switch/conditional case body: alias the result to
        // the image operand's name exactly like the main emit path, so the sample
        // op that consumes it resolves the real texture. Previously this op fell
        // to the replay fallback and honest-errored ("unsupported op
        // 'SampledImage' in switch/loop replay path"), refusing shaders whose
        // only sin was a textureSample inside a switch default arm.
        .SampledImage => {
            if (inst.words.len > 4) {
                const image_name = names.get(inst.words[3]) orelse "tex";
                if (try names.fetchPut(inst.words[2], try alloc.dupe(u8, image_name))) |old| alloc.free(old.value);
            }
        },
        // OpImageSampleImplicitLod in a case body: the MINIMAL faithful form,
        // a plain float texture, no image operands, non-arrayed, lowered exactly
        // like the main emit path (textureSample with the call-site sampler when
        // the OpSampledImage carries one). Anything richer (bias/lod/grad/offset
        // operands, arrayed or multisample shapes, integer textures) keeps the
        // honest error rather than a guessed lowering.
        .ImageSampleImplicitLod => {
            if (isIntegerSampledImage(module, inst.words[3])) return error.UnsupportedIntegerTextureSample;
            const mask: u32 = if (inst.words.len > 5) inst.words[5] else 0;
            if (mask != 0) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL switch/loop replay path lowers only a plain textureSample (image operands are unsupported here)", .{}) catch null;
                return error.UnsupportedImageOperands;
            }
            const shape = arrayedSampleShape(module, inst.words[3]);
            if (shape.arrayed or shape.depth) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL switch/loop replay path lowers only a plain non-arrayed textureSample", .{}) catch null;
                return error.UnsupportedImageOperands;
            }
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const tex_name = names.get(inst.words[3]) orelse "tex";
            const sampler_arg = resolveSamplerArg(module, names, inst.words[3], tex_name, arena);
            const coord = resolveOperandExpr(module, names, inline_exprs, inst.words[4], arena, 0);
            try writeIndentStatic(w, indent);
            // #wgsl-uniformity-8k2: a sample inside a switch CASE is in
            // non-uniform flow whenever the selector is (probe p14), so the
            // replay path applies the same level-0 downgrade as the main walk.
            // Builtin and level picked into consts and printed once, the shape
            // the main path and the Dref arms use.
            const nonuniform_flow = nonuniform_gated.contains(inst.words[2]);
            const builtin: []const u8 = if (nonuniform_flow) "textureSampleLevel" else "textureSample";
            const level_arg: []const u8 = if (nonuniform_flow) ", 0.0" else "";
            try w.print("let {s}: {s} = {s}({s}, {s}, {s}{s});\n", .{ result_name, rt, builtin, tex_name, sampler_arg, coord, level_arg });
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
            // Extract from OpConstantNull: fold to the zero literal of the result
            // type (see the main emit path; the composite's own type, e.g. a
            // flattened io struct, may not be declared in the output).
            if (getDef(module, inst.words[3])) |bd| {
                if (bd.op == .ConstantNull) {
                    if (zeroLiteralOfType(module, inst.words[1], names, alloc)) |z| {
                        if (try names.fetchPut(result_id, z)) |old| alloc.free(old.value);
                        return;
                    }
                }
            }
            const composite = names.get(inst.words[3]) orelse "c";
            // #rm-extract: same row-major compensation as the main emit path --
            // an extract reaching a row-major matrix member of a RAW composite
            // value reads M^T and needs transpose(...); UNKNOWN provenance
            // fails loudly instead of guessing.
            if (inst.words.len > 4) {
                if (findRowMajorExtract(module, inst.words[3], inst.words[4..])) |hit| {
                    switch (valueBytesProvenance(module, inst.words[3], 0)) {
                        .raw => {
                            var texpr = std.ArrayList(u8).initCapacity(alloc, 64) catch return;
                            defer texpr.deinit(alloc);
                            texpr.appendSlice(alloc, "transpose(") catch return;
                            texpr.appendSlice(alloc, composite) catch return;
                            appendExtractPrefix(module, inst.words[3], inst.words[4 .. hit.boundary + 5], &texpr, alloc) catch return;
                            texpr.appendSlice(alloc, ")") catch return;
                            appendMatrixTailLiterals(module, hit.matrix_tid, inst.words[hit.boundary + 5 ..], &texpr, alloc) catch return;
                            if (try names.fetchPut(result_id, try alloc.dupe(u8, texpr.items))) |old| alloc.free(old.value);
                            return;
                        },
                        .logical => {}, // registers hold the logical matrix: plain path
                        .unknown => return error.UnsupportedRowMajorExtractProvenance,
                    }
                }
            }
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
                            const sw = switch (idx) {
                                0 => ".x",
                                1 => ".y",
                                2 => ".z",
                                3 => ".w",
                                else => ".x",
                            };
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
            // A struct/array result has no select() form — lower to var + if/else
            // (same as the main emit path).
            if (std.mem.startsWith(u8, rt, "struct") or std.mem.startsWith(u8, rt, "array") or
                isStructType(module, inst.words[1]) or isArrayType(module, inst.words[1]))
            {
                try writeIndentStatic(w, indent);
                try w.print("var {s}: {s};\n", .{ result_name, rt });
                try writeIndentStatic(w, indent);
                try w.print("if ({s}) {{\n", .{cond});
                try writeIndentStatic(w, indent + 1);
                try w.print("{s} = {s};\n", .{ result_name, true_val });
                try writeIndentStatic(w, indent);
                try w.writeAll("} else {\n");
                try writeIndentStatic(w, indent + 1);
                try w.print("{s} = {s};\n", .{ result_name, false_val });
                try writeIndentStatic(w, indent);
                try w.writeAll("}\n");
            } else {
                try writeIndentStatic(w, indent);
                try w.print("let {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
            }
        },
        .Bitcast => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            const result_name = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "0";
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = bitcast<{s}>({s});\n", .{ result_name, rt, rt, val });
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
        // LogicalNot — mirror the main emitBody arm exactly (`let r: T = !x`). The replay
        // path re-emits this when a `!x` lands in a deferred loop/switch replay range.
        .LogicalNot => {
            const rt = try wgslType(module, inst.words[1], names, arena);
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = !{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "true" });
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
                    try writeIndentStatic(w, indent);
                    try w.print("let {s}: {s} = spvInverse{d}({s});\n", .{ result_name, rt, dim, m });
                    return;
                }
                if (scalarGeomLower(arena, module, names, instruction, inst.words[1], inst.words[5..])) |sexpr| {
                    try writeIndentStatic(w, indent);
                    try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, sexpr });
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
                    try writeIndentStatic(w, indent);
                    try w.print("let {s}: {s} = {s}({s}({s}));\n", .{ result_name, rt, rt, func_name, args.items });
                } else {
                    try writeIndentStatic(w, indent);
                    try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
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
            try writeIndentStatic(w, indent);
            try w.print("let {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, args.items });
        },
        .SelectionMerge, .LoopMerge => {
            // Structured control-flow merge hints — they carry no result id and
            // are consumed by the enclosing switch/if/loop replay. Emit nothing
            // (otherwise the generic fallback below leaks the opcode name as a
            // value, e.g. `let v = SelectionMerge();`, which naga rejects).
        },
        // #170: shifts must go through emitShift here too, not the generic
        // emitBinOp the `else` arm reaches via getBinOpSymbol — otherwise a
        // constant over-shift re-emitted in a switch-case body (or any other
        // replay) is unmasked + un-u32-cast = naga-rejected (silent-wrong), the
        // same gap the main emit path fixes. (ShiftRightArithmetic isn't in
        // getBinOpSymbol at all, so it used to fail loud here.)
        .ShiftLeftLogical => try emitShift(module, names, inline_exprs, inst, "<<", w, arena, indent),
        .ShiftRightLogical, .ShiftRightArithmetic => try emitShift(module, names, inline_exprs, inst, ">>", w, arena, indent),
        // OpFMod needs the sign-of-divisor floor expansion, not `%` (see emitFMod);
        // route it here too so a replayed FMod (switch-case body / CFG replay) is
        // not re-emitted as the wrong `%` via getBinOpSymbol below.
        .FMod => try emitFMod(module, names, inline_exprs, inst, w, arena, indent),
        // OpSMod floored lowering here too (replay path) -- getBinOpSymbol has no `%` entry
        // for it, so it would otherwise fail loud in a switch/loop body. (#170)
        .SMod => try emitSMod(module, names, inline_exprs, inst, w, arena, indent),
        // Unordered float inequalities need the `!(ordered complement)` lowering
        // (see emitUnorderedCompare), not the ordered `<`/`>=` the generic
        // getBinOpSymbol path below would emit -- route them here too so a replayed
        // FUnord* (switch-case body / CFG replay) is exact on NaN, not silent-wrong.
        // (getBinOpSymbol has no entry for them, so they would otherwise fail loud.) (#170)
        .FUnordLessThan => try emitUnorderedCompare(module, names, inline_exprs, inst, ">=", w, arena, indent),
        .FUnordGreaterThan => try emitUnorderedCompare(module, names, inline_exprs, inst, "<=", w, arena, indent),
        .FUnordLessThanEqual => try emitUnorderedCompare(module, names, inline_exprs, inst, ">", w, arena, indent),
        .FUnordGreaterThanEqual => try emitUnorderedCompare(module, names, inline_exprs, inst, "<", w, arena, indent),
        .FUnordEqual => try emitUnorderedEqual(module, names, inline_exprs, inst, w, arena, indent),
        // OpFOrdNotEqual needs the `!(FUnordEqual)` lowering (see emitOrderedNotEqual),
        // not the bare `!=` the generic getBinOpSymbol path below would emit (WGSL !=
        // is unordered = true on NaN, but FOrdNotEqual is false on NaN). (#170)
        .FOrdNotEqual => try emitOrderedNotEqual(module, names, inline_exprs, inst, w, arena, indent),
        else => {
            // #wgsl-replay-twin-drift: route the pure-expression ops the main
            // dispatch emits natively through the SHARED emitters, so case-body
            // and loop-header replay cannot drift from the main arms. Control
            // flow ops stay honest-errors (a statement emitter must not guess
            // phi/return semantics).
            switch (inst.op) {
                // VectorShuffle is deliberately NOT routed here yet: routing it
                // unmasks a LATENT class where the
                // if-arm replay's live names-map overwrites are shadowed by
                // STALE inline_exprs entries (built at pre-scan with bare
                // minted names) — gf_028 emitted `(v22 + v20)` for inlined
                // extract exprs and exited 0 with naga-invalid output. Honest
                // refusal until that staleness is fixed (zioshade-afi notes);
                // BitFieldSExtract is a pure builtin call over plain operand
                // names (no inline interplay) and is verified naga-clean on
                // gf_058/072.
                .BitFieldSExtract, .BitFieldUExtract => try emitBitFieldExtractWgsl(module, names, inst, w, arena, indent),
                .BitReverse => try emitBitReverseWgsl(module, names, inst, w, arena, indent),
                .BitCount => try emitBitCountWgsl(module, names, inst, w, arena, indent),
                .CompositeInsert => try emitCompositeInsertWgsl(module, names, inst, w, arena, indent),
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
        // OpFMod deliberately absent: WGSL float `%` has the wrong (dividend) sign,
        // so FMod must not be inlined/replayed as `%` — it routes to emitFMod.
        .SRem, .FRem, .UMod => "%", // NOT .SMod -- it needs the floored `((x%y)+y)%y`, see emitSMod (#170)
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
        .FUnordNotEqual => "!=",
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
        .UConvert => switch (op) {
            else => null,
        },
        .FConvert => "f32",
        .SConvert => "i32",
        .SNegate => "-",
        .FNegate => "-",
        .Not => "!",
        .Bitcast => "bitcast", // will be handled specially
        else => null,
    };
}

/// Derivative emission shared by all nine OpDPdx*/OpDPdy*/OpFwidth* arms: a
/// derivative the uniformity prepass marked as sitting in non-uniform flow
/// (#685) is REFUSED (WGSL gates it on uniform control flow and there is no
/// explicit-derivative form to lower to); anything else is the plain
/// one-to-one builtin via emitCall.
fn emitDerivative(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, nonuniform_gated: *const std.AutoHashMap(u32, void), func: []const u8, w: anytype, arena: std.mem.Allocator, indent: u32) !void {
    if (nonuniform_gated.contains(inst.words[2])) return recordUnsupportedNonuniformDerivative();
    return emitCall(module, names, inst, func, w, arena, indent);
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
    try writeIndentStatic(w, indent);
    try w.print("var {s}: {s} = {s}({s});\n", .{ result_name, rt, func, args.items });
}

// (emitSubgroupArith removed in #170 G5 Pass 2, then the whole family restored
// as emitSubgroupOp once tint became the validation oracle for subgroups: the
// local naga cannot parse `enable subgroups;`, so the #641-era state was a
// blanket refusal of 546 CTS cases. See the subgroup arms in emitBody.)

/// True for the OpGroupNonUniform*/OpSubgroup*KHR ops the WGSL backend
/// LOWERS (the dialect's subgroup builtins under `enable subgroups;`). The
/// families with no faithful spelling (AllEqual, Logical*, ballot-bit ops,
/// Rotate) are deliberately absent: they refuse in their own emitBody arm.
fn opIsLoweredSubgroup(op: spirv.Op) bool {
    return switch (op) {
        .GroupNonUniformElect,
        .GroupNonUniformAll,
        .GroupNonUniformAny,
        .GroupNonUniformBroadcast,
        .GroupNonUniformBroadcastFirst,
        .GroupNonUniformBallot,
        .GroupNonUniformShuffle,
        .GroupNonUniformShuffleXor,
        .GroupNonUniformShuffleUp,
        .GroupNonUniformShuffleDown,
        .GroupNonUniformIAdd,
        .GroupNonUniformFAdd,
        .GroupNonUniformIMul,
        .GroupNonUniformFMul,
        .GroupNonUniformSMin,
        .GroupNonUniformUMin,
        .GroupNonUniformFMin,
        .GroupNonUniformSMax,
        .GroupNonUniformUMax,
        .GroupNonUniformFMax,
        .GroupNonUniformBitwiseAnd,
        .GroupNonUniformBitwiseOr,
        .GroupNonUniformBitwiseXor,
        .GroupNonUniformQuadBroadcast,
        .GroupNonUniformQuadSwap,
        .SubgroupAllKHR,
        .SubgroupAnyKHR,
        => true,
        else => false,
    };
}

/// True for the subgroup BuiltIns that have a WGSL @builtin spelling and so
/// require `enable subgroups;` in the output.
fn builtInNeedsSubgroupsEnable(bi: spirv.BuiltIn) bool {
    return bi == .subgroup_local_invocation_id or bi == .subgroup_size;
}

/// WGSL subgroup-builtin name for an OpGroupNonUniform arithmetic op, keyed by
/// the GroupOperation literal (words[4]). MSL's mslEmitSubgroupArith is the
/// semantic reference: Reduce/InclusiveScan/ExclusiveScan map to the same
/// three WGSL shapes, and only Add/Mul have scan forms in the dialect -- a
/// min/max/bitwise scan or a ClusteredReduce refuses (no builtin, and an
/// arithmetic emulation would not match the hardware op).
fn subgroupArithName(inst: Instruction) error{ UnsupportedOp, OutOfMemory }![]const u8 {
    const gop = if (inst.words.len > 4) inst.words[4] else 0;
    switch (gop) {
        0 => return switch (inst.op) { // Reduce
            .GroupNonUniformIAdd, .GroupNonUniformFAdd => "subgroupAdd",
            .GroupNonUniformIMul, .GroupNonUniformFMul => "subgroupMul",
            .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => "subgroupMin",
            .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => "subgroupMax",
            .GroupNonUniformBitwiseAnd => "subgroupAnd",
            .GroupNonUniformBitwiseOr => "subgroupOr",
            .GroupNonUniformBitwiseXor => "subgroupXor",
            else => return error.UnsupportedOp,
        },
        1 => return switch (inst.op) { // InclusiveScan: only Add/Mul exist
            .GroupNonUniformIAdd, .GroupNonUniformFAdd => "subgroupInclusiveAdd",
            .GroupNonUniformIMul, .GroupNonUniformFMul => "subgroupInclusiveMul",
            else => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no inclusive-scan subgroup form for {s} (only Add/Mul)", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            },
        },
        2 => return switch (inst.op) { // ExclusiveScan: only Add/Mul exist
            .GroupNonUniformIAdd, .GroupNonUniformFAdd => "subgroupExclusiveAdd",
            .GroupNonUniformIMul, .GroupNonUniformFMul => "subgroupExclusiveMul",
            else => {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no exclusive-scan subgroup form for {s} (only Add/Mul)", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            },
        },
        else => { // 3 = ClusteredReduce (cluster size in words[6]): no WGSL form
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL has no clustered subgroup form ({s} ClusteredReduce)", .{@tagName(inst.op)}) catch null;
            return error.UnsupportedOp;
        },
    }
}

/// True if the variable has any OpStore targeting it (directly or through an
/// AccessChain rooted at it) anywhere in the module.
fn varHasRuntimeStore(module: *const ParsedModule, var_id: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op != .Store or inst.words.len < 2) continue;
        if (inst.words[1] == var_id) return true;
        if (getDef(module, inst.words[1])) |t| {
            if (t.op == .AccessChain and t.words.len > 3 and t.words[3] == var_id) return true;
        }
    }
    return false;
}

/// True if the value id's defining expression (bounded depth, pure value ops
/// only) reads a module-scope Private variable that is written at runtime and
/// is NOT covered by single-store forwarding. WGSL's uniformity analysis
/// (tint) conservatively treats such a read as non-uniform, and the subgroup
/// builtins with a uniform-value argument (shuffle delta/mask, broadcast and
/// quad ids) REJECT it. zioshade has no call-graph-wide uniform spelling for
/// such a value (a written module-scope private is the only WGSL construct
/// that crosses functions), so the caller refuses rather than emit output the
/// oracle rejects.
fn valueReadsRuntimePrivate(module: *const ParsedModule, id: u32, depth: u32) bool {
    if (depth == 0) return false;
    const d = getDef(module, id) orelse return false;
    switch (d.op) {
        .Load => {
            if (d.words.len < 4) return false;
            const ptr = d.words[3];
            if (getDef(module, ptr)) |pv| {
                if (pv.op == .Variable and pv.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(pv.words[3]);
                    if (sc == .Private and !forward_private_stores.contains(ptr) and varHasRuntimeStore(module, ptr)) return true;
                }
                if (pv.op == .AccessChain and pv.words.len > 3) {
                    return valueReadsRuntimePrivate(module, pv.words[3], depth - 1);
                }
            }
            return false;
        },
        // Pure arithmetic/bitwise/shift/divrem binaries: recurse both operands.
        .IAdd, .ISub, .IMul, .UDiv, .SDiv, .UMod, .SRem, .SMod, .BitwiseAnd, .BitwiseOr, .BitwiseXor, .ShiftLeftLogical, .ShiftRightLogical, .ShiftRightArithmetic, .LogicalAnd, .LogicalOr, .LogicalEqual, .LogicalNotEqual => {
            if (d.words.len > 4 and valueReadsRuntimePrivate(module, d.words[4], depth - 1)) return true;
            if (d.words.len > 3 and valueReadsRuntimePrivate(module, d.words[3], depth - 1)) return true;
            return false;
        },
        else => return false,
    }
}

/// Lower one OpGroupNonUniform* / OpSubgroupAllKHR/AnyKHR to its WGSL subgroup
/// builtin. Instruction layouts (scope word must be Subgroup == 3; the KHR vote
/// forms carry no scope word):
///   OpGroupNonUniformElect                       bool r scope
///   OpGroupNonUniform{All,Any,Ballot,
///                     BroadcastFirst}            T    r scope v
///   OpGroupNonUniform{Broadcast,Shuffle,ShuffleXor,
///                     ShuffleUp,ShuffleDown,
///                     QuadBroadcast}             T    r scope v id
///   OpGroupNonUniformQuadSwap                    T    r scope v direction-const
///   OpGroupNonUniform{IAdd..BitwiseXor}          T    r scope groupop v
///   OpSubgroup{All,Any}KHR                       bool r predicate
fn emitSubgroupOp(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    inst: Instruction,
    w: anytype,
    arena: std.mem.Allocator,
    indent: u32,
) !void {
    // WGSL subgroup builtins are compute/fragment only (tint: "built-in cannot
    // be used by vertex pipeline stage"). Emitting one for another stage would
    // produce oracle-rejected output, so refuse before writing anything.
    switch (module.execution_model) {
        .GLCompute, .Fragment => {},
        else => {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL subgroup operations are compute/fragment only ({s} in {s})", .{ @tagName(inst.op), @tagName(module.execution_model) }) catch null;
            return error.UnsupportedOp;
        },
    }
    const has_scope = inst.op != .SubgroupAllKHR and inst.op != .SubgroupAnyKHR;
    // Length guard FIRST: truncated/corrupt modules must not index out of
    // bounds. 4 = opcode+type+id+one word; 5/6 = the operand shapes above.
    const min_words: usize = if (!has_scope) 4 else if (inst.op == .GroupNonUniformElect) 4 else if (inst.op == .GroupNonUniformAll or inst.op == .GroupNonUniformAny or inst.op == .GroupNonUniformBallot or inst.op == .GroupNonUniformBroadcastFirst) 5 else 6;
    if (inst.words.len < min_words) return error.UnsupportedOp;
    if (has_scope) {
        // The execution scope is an operand ID referencing a scope CONSTANT
        // (glslang/tint emit OpConstant 3), not a literal. Resolve it: WGSL's
        // subgroup builtins are SUBGROUP-scoped, and a wider execution scope
        // (Workgroup/Device) has no spelling; silently narrowing it to subgroup
        // scope would change the op's semantics -- a miscompile. Fail loud.
        var scope: i64 = -1;
        if (getDef(module, inst.words[3])) |d| {
            if (d.op == .Constant and d.words.len > 3) scope = @as(i32, @bitCast(d.words[3]));
        }
        if (scope != 3) {
            last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL subgroup builtins are subgroup-scoped; {s} carries execution scope {d} != 3", .{ @tagName(inst.op), scope }) catch null;
            return error.UnsupportedOp;
        }
    }
    const rt = try wgslType(module, inst.words[1], names, arena);
    const rn = names.get(inst.words[2]) orelse "v";

    // Uniform-value argument guard: the shuffle delta/mask and the broadcast/
    // quad id must be uniform across the subgroup. If the argument expression
    // reads a runtime-written module-scope private that forwarding could not
    // eliminate (its store and its loads span functions -- tint's own
    // `tint_subgroup_size_mask` idiom when a helper holds the shuffle), no WGSL
    // spelling keeps the value uniform: refuse rather than emit output the
    // oracle rejects as non-uniform.
    switch (inst.op) {
        .GroupNonUniformBroadcast, .GroupNonUniformShuffle, .GroupNonUniformShuffleXor, .GroupNonUniformShuffleUp, .GroupNonUniformShuffleDown, .GroupNonUniformQuadBroadcast => {
            if (valueReadsRuntimePrivate(module, inst.words[5], 8)) {
                last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL requires a uniform {s} id/delta, but the argument reads a runtime-written module-scope private across functions (tint's uniformity analysis rejects it and no cross-function uniform spelling exists)", .{@tagName(inst.op)}) catch null;
                return error.UnsupportedOp;
            }
        },
        else => {},
    }

    var fname: []const u8 = undefined;
    var arg_ids: [2]u32 = .{ 0, 0 };
    var n_args: usize = 0;
    switch (inst.op) {
        .GroupNonUniformElect => fname = "subgroupElect",
        .GroupNonUniformAll => {
            fname = "subgroupAll";
            arg_ids[0] = inst.words[4];
            n_args = 1;
        },
        .GroupNonUniformAny => {
            fname = "subgroupAny";
            arg_ids[0] = inst.words[4];
            n_args = 1;
        },
        .SubgroupAllKHR => {
            fname = "subgroupAll";
            arg_ids[0] = inst.words[3]; // KHR vote forms have no scope word
            n_args = 1;
        },
        .SubgroupAnyKHR => {
            fname = "subgroupAny";
            arg_ids[0] = inst.words[3];
            n_args = 1;
        },
        .GroupNonUniformBroadcastFirst => {
            fname = "subgroupBroadcastFirst";
            arg_ids[0] = inst.words[4];
            n_args = 1;
        },
        .GroupNonUniformBallot => {
            fname = "subgroupBallot";
            arg_ids[0] = inst.words[4];
            n_args = 1;
        },
        .GroupNonUniformBroadcast => {
            fname = "subgroupBroadcast";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformShuffle => {
            fname = "subgroupShuffle";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformShuffleXor => {
            fname = "subgroupShuffleXor";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformShuffleUp => {
            fname = "subgroupShuffleUp";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformShuffleDown => {
            fname = "subgroupShuffleDown";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformQuadBroadcast => {
            fname = "quadBroadcast";
            arg_ids[0] = inst.words[4];
            arg_ids[1] = inst.words[5];
            n_args = 2;
        },
        .GroupNonUniformQuadSwap => {
            // The direction selects the FUNCTION, not an argument. Per the
            // SPIR-V spec it must be a Constant instruction: Horizontal(0) ->
            // quadSwapX, Vertical(1) -> quadSwapY, Diagonal(2) ->
            // quadSwapDiagonal. A non-constant or out-of-range direction has
            // no WGSL spelling (the WGSL quad swaps are three distinct
            // builtins), so fail loud rather than guess.
            const dir_id = inst.words[5];
            var dir: i64 = -1;
            if (getDef(module, dir_id)) |d| {
                if (d.op == .Constant and d.words.len > 3) dir = @as(i32, @bitCast(d.words[3]));
            }
            fname = switch (dir) {
                0 => "quadSwapX",
                1 => "quadSwapY",
                2 => "quadSwapDiagonal",
                else => {
                    last_error_detail = std.fmt.bufPrint(&last_error_detail_buf, "WGSL quad swaps are three distinct builtins; OpGroupNonUniformQuadSwap direction {d} is not 0/1/2 or not a constant", .{dir}) catch null;
                    return error.UnsupportedOp;
                },
            };
            arg_ids[0] = inst.words[4];
            n_args = 1;
        },
        else => {
            // Arithmetic family: words[4] is the GroupOperation literal (NOT an
            // operand), the value is words[5]. MSL reads the same positions.
            fname = try subgroupArithName(inst);
            arg_ids[0] = inst.words[5];
            n_args = 1;
        },
    }
    var args: std.ArrayList(u8) = .empty;
    for (arg_ids[0..n_args], 0..) |aid, ai| {
        if (ai > 0) try args.appendSlice(arena, ", ");
        try args.appendSlice(arena, names.get(aid) orelse "0");
    }
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = {s}({s});\n", .{ rn, rt, fname, args.items });
}

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
    try writeIndentStatic(w, indent);
    try w.print("let {s}: {s} = atomic{s}(&{s}, {s});\n", .{ result_name, rt, op, ptr, val });
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
        // OpFMod excluded: it must not be inlined as `%` (wrong sign in WGSL); it
        // routes to emitFMod's floor expansion as a named statement instead.
        .FMul, .FAdd, .FSub, .FDiv, .FNegate, .IMul, .IAdd, .ISub, .SDiv, .UDiv, .VectorTimesScalar, .MatrixTimesScalar, .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual, .FOrdEqual, .FUnordNotEqual, .ExtInst => true,
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
        // NOT .SMod -- floored, needs `((x%y)+y)%y` (emitSMod), never a bare `%`. (#170)
        .FOrdLessThan => "<",
        .FOrdGreaterThan => ">",
        .FOrdLessThanEqual => "<=",
        .FOrdGreaterThanEqual => ">=",
        .FOrdEqual => "==",
        .FUnordNotEqual => "!=",
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
        // Binary arithmetic ops: lhs op rhs (OpFMod excluded — wrong-sign `%` in
        // WGSL; it is never inlined, see isInlineableArithOp / emitFMod)
        .FMul, .FAdd, .FSub, .FDiv, .IMul, .IAdd, .ISub, .SDiv, .UDiv, .VectorTimesScalar, .MatrixTimesScalar, .FOrdLessThan, .FOrdGreaterThan, .FOrdLessThanEqual, .FOrdGreaterThanEqual, .FOrdEqual, .FUnordNotEqual => {
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
                if (!gop.found_existing) gop.value_ptr.* = .empty;
            },
            .FunctionEnd => cur = 0,
            .FunctionCall => if (inst.words.len >= 4 and cur != 0) {
                const gop = adj.getOrPut(cur) catch return false;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
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
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
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
