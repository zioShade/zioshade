// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → HLSL cross-compiler backend.
//!
//! Parses a SPIR-V binary into an instruction stream, resolves types/decorations,
//! and emits HLSL Shader Model 6.0 source code.
//!
//! Currently targeting fragment shaders for wintty integration.

const compat = @import("compat.zig");
const std = @import("std");
const spirv = @import("spirv.zig");

const common = @import("spirv_cross_common.zig");

const log = std.log.scoped(.spirv_to_hlsl);

// ---------------------------------------------------------------------------
// SPIR-V Binary Parser
// ---------------------------------------------------------------------------

const LoopInfo = struct { merge: u32, cont: u32 };

/// A loop-header OpPhi (the loop counter): must be materialized as a mutable
/// variable `TYPE name = <init>;` before the loop and updated `name = <update>;`
/// at the back-edge, else the counter freezes at its init value (#gaps: phi-loop).
const PhiInfo = struct { result_id: u32, type_id: u32, init_id: u32, update_id: u32 };

/// HLSL type name for a loop-phi variable declaration. Returns STATIC strings
/// only (no allocation, so no free management) for the scalar/vector types loop
/// phis realistically carry. Falls back to "int" for exotic (matrix/struct) phis.
fn phiTypeNameHLSL(module: *const ParsedModule, type_id: u32) []const u8 {
    const tinst = getDef(module, type_id) orelse return "int";
    switch (tinst.op) {
        .TypeBool => return "bool",
        .TypeInt => return if (tinst.words.len > 3 and tinst.words[3] != 0) "int" else "uint",
        .TypeFloat => return if (tinst.words.len > 2 and tinst.words[2] == 16) "half" else "float",
        .TypeVector => {
            const scalar = phiTypeNameHLSL(module, tinst.words[2]);
            const cols = tinst.words[3];
            if (cols < 1 or cols > 4) return "int";
            const idx: usize = cols;
            if (std.mem.eql(u8, scalar, "float")) return ([_][]const u8{ "", "float", "float2", "float3", "float4" })[idx];
            if (std.mem.eql(u8, scalar, "half")) return ([_][]const u8{ "", "half", "half2", "half3", "half4" })[idx];
            if (std.mem.eql(u8, scalar, "int")) return ([_][]const u8{ "", "int", "int2", "int3", "int4" })[idx];
            if (std.mem.eql(u8, scalar, "uint")) return ([_][]const u8{ "", "uint", "uint2", "uint3", "uint4" })[idx];
            if (std.mem.eql(u8, scalar, "bool")) return ([_][]const u8{ "", "bool", "bool2", "bool3", "bool4" })[idx];
            return "int";
        },
        else => return "int",
    }
}

const Instruction = struct {
    op: spirv.Op,
    words: []const u32,
};

const MeshTopology = enum { triangles, lines, points };

const ParsedModule = struct {
    instructions: []const Instruction,
    id_defs: []const ?usize,
    entry_point_id: ?u32 = null,
    execution_model: spirv.ExecutionModel = .Fragment,
    local_size: [3]u32 = [3]u32{ 1, 1, 1 },
    early_fragment_tests: bool = false,
    mesh_topology: ?MeshTopology = null,
    mesh_max_vertices: ?u32 = null,
    mesh_max_primitives: ?u32 = null,

    pub fn deinit(self: *ParsedModule, alloc: std.mem.Allocator) void {
        // instructions was allocated via ArrayList.initCapacity
        // The slice points into that allocation
        if (self.instructions.len > 0) {
            // Free the backing allocation (from ArrayList)
            // We need to reconstruct the slice as the ArrayList allocated it
            const bytes = @constCast(self.instructions.ptr);
            alloc.free(bytes[0..self.instructions.len]);
        }
        alloc.free(@constCast(self.id_defs.ptr)[0..self.id_defs.len]);
    }
};

fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;

    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch
        return error.OutOfMemory;
    errdefer instructions.deinit(alloc);

    const bound = if (words.len > 3) words[3] else 0;
    const id_defs = try alloc.alloc(?usize, bound);
    @memset(id_defs, null);

    var i: usize = 5;
    while (i < words.len) {
        const header_word = words[i];
        const word_count: u16 = @intCast(header_word >> 16);
        const opcode: u16 = @truncate(header_word & 0xFFFF);

        if (word_count == 0) return error.InvalidSpirv;
        if (i + word_count > words.len) return error.InvalidSpirvTruncated;

        const op: spirv.Op = @enumFromInt(opcode);
        const inst_words = words[i .. i + word_count];

        if (resultIdFromOp(op, inst_words)) |id| {
            if (id < bound) id_defs[id] = instructions.items.len;
        }

        instructions.append(alloc, .{ .op = op, .words = inst_words }) catch
            return error.OutOfMemory;

        i += word_count;
    }

    const owned_instructions = instructions.toOwnedSlice(alloc) catch instructions.items;
    var module = ParsedModule{
        .instructions = owned_instructions,
        .id_defs = id_defs,
    };

    // Extract entry point and execution mode
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) {
            if (module.entry_point_id == null) {
                module.execution_model = @enumFromInt(inst.words[1]);
                module.entry_point_id = inst.words[2];
            }
        }
        if (inst.op == .ExecutionMode and inst.words.len >= 3) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSize and inst.words.len >= 6) {
                module.local_size = .{
                    inst.words[3],
                    inst.words[4],
                    inst.words[5],
                };
            }
            if (mode == .EarlyFragmentTests) {
                module.early_fragment_tests = true;
            }
            // Mesh shader execution modes (M5.2)
            if (mode == .OutputTrianglesEXT) {
                module.mesh_topology = .triangles;
            } else if (mode == .OutputLinesEXT) {
                module.mesh_topology = .lines;
            } else if (mode == .OutputPoints) {
                // OutputPoints (27) is shared with geometry shaders; only treat as
                // mesh topology when the entry point is a mesh shader.
                if (module.execution_model == .MeshEXT) {
                    module.mesh_topology = .points;
                }
            } else if (mode == .OutputVertices and inst.words.len >= 4) {
                module.mesh_max_vertices = inst.words[3];
            } else if (mode == .OutputPrimitivesEXT and inst.words.len >= 4) {
                module.mesh_max_primitives = inst.words[3];
            }
        }
    }

    return module;
}

/// True if `var_id` is ever written — directly or through a single-level access
/// chain. Detects only direct + one-level-chain stores; sufficient because a
/// `const` global (the only thing carrying a const initializer here) is never
/// written. Deeper-chain / pass-by-pointer mutation in ingested SPIR-V is the
/// only blind spot.
fn hlslPrivateVarMutated(module: *const ParsedModule, var_id: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op == .Store and inst.words.len >= 2 and inst.words[1] == var_id) return true;
        if (inst.op == .AccessChain and inst.words.len >= 4 and inst.words[3] == var_id) {
            const chain_id = inst.words[2];
            for (module.instructions) |s| {
                if (s.op == .Store and s.words.len >= 2 and s.words[1] == chain_id) return true;
            }
        }
    }
    return false;
}

/// Design A — if `inst` is a never-written Private OpVariable with a constant
/// initializer operand, return the initializer constant id; else null. The
/// variable is aliased to its promoted const literal (HLSL emits the array
/// ConstantComposite as `static const T v[N] = {…}`), so `v[i]` resolves to the
/// const and the uninitialised `static T v[N];` declaration is skipped.
fn hlslConstInitializedPrivateVar(module: *const ParsedModule, inst: Instruction) ?u32 {
    if (inst.op != .Variable or inst.words.len < 5) return null;
    const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
    if (sc != .Private) return null;
    const init_id = inst.words[4];
    const init_def = getDef(module, init_id) orelse return null;
    switch (init_def.op) {
        .Constant, .ConstantComposite, .ConstantTrue, .ConstantFalse => {},
        else => return null,
    }
    if (hlslPrivateVarMutated(module, inst.words[2])) return null;
    return init_id;
}

fn hlslAliasConstInitializedPrivateVars(alloc: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    for (module.instructions) |inst| {
        const init_id = hlslConstInitializedPrivateVar(module, inst) orelse continue;
        const var_id = inst.words[2];
        const init_name = names.get(init_id) orelse continue;
        const dup = alloc.dupe(u8, init_name) catch continue;
        if (names.fetchPut(var_id, dup) catch null) |old| alloc.free(old.value);
    }
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
    return switch (op) {
        // Types: result at word[1]
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix,
        .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray,
        .TypeStruct, .TypePointer, .TypeFunction, .TypeForwardPointer,
        .TypeAccelerationStructureKHR, .TypeRayQueryKHR, .TypeTensorARM,
        => if (words.len > 1) words[1] else null,

        // Constants: type=word[1], result=word[2]
        .ConstantTrue, .ConstantFalse, .Constant, .ConstantComposite,
        .SpecConstant, .SpecConstantTrue, .SpecConstantFalse,
        .SpecConstantComposite, .SpecConstantOp, .Undef,
        => if (words.len > 2) words[2] else null,

        // Variable/Function/Param: type=word[1], result=word[2]
        .Variable, .Function, .FunctionParameter,
        => if (words.len > 2) words[2] else null,

        // Most computation ops: type=word[1], result=word[2]
        .Load, .AccessChain, .CompositeConstruct, .CompositeExtract, .CompositeInsert,
        .VectorShuffle, .SampledImage, .ImageSampleImplicitLod,
        .ImageSampleExplicitLod, .ImageFetch, .ImageGather,
        .ImageQuerySizeLod, .ImageQuerySize,
        .ImageTexelPointer, .FunctionCall,
        .CopyObject, .Phi,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast,
        .SNegate, .FNegate,
        .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul,
        .UDiv, .SDiv, .FDiv, .UMod, .SRem, .SMod, .FRem, .FMod,
        .VectorTimesScalar, .MatrixTimesScalar,
        .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix,
        .Dot, .Transpose, .OuterProduct,
        .Select, .LogicalOr, .LogicalAnd, .LogicalNot,
        .IEqual, .INotEqual,
        .UGreaterThan, .SGreaterThan, .UGreaterThanEqual, .SGreaterThanEqual,
        .ULessThan, .SLessThan, .ULessThanEqual, .SLessThanEqual,
        .FOrdEqual, .FOrdNotEqual, .FOrdLessThan, .FOrdGreaterThan,
        .FOrdLessThanEqual, .FOrdGreaterThanEqual,
        .FUnordEqual, .FUnordNotEqual, .FUnordLessThan, .FUnordGreaterThan,
        .FUnordLessThanEqual, .FUnordGreaterThanEqual,
        .ShiftRightLogical, .ShiftRightArithmetic, .ShiftLeftLogical,
        .BitwiseOr, .BitwiseXor, .BitwiseAnd, .Not,
        .IsNan, .IsInf, .All, .Any,
        .DPdx, .DPdy, .Fwidth, .DPdxFine, .DPdyFine, .FwidthFine,
        .DPdxCoarse, .DPdyCoarse, .FwidthCoarse,
        .VectorExtractDynamic,
        .ExtInst, .OpImage,
        .AtomicIAdd, .AtomicISub, .AtomicExchange,
        .AtomicSMin, .AtomicUMin, .AtomicSMax, .AtomicUMax,
        .AtomicAnd, .AtomicOr, .AtomicXor,
        .ImageSampleDrefImplicitLod, .ImageSampleDrefExplicitLod,
        .ImageSampleProjImplicitLod, .ImageSampleProjExplicitLod,
        .ImageDrefGather, .ImageQueryLod, .ImageQueryLevels, .ImageQuerySamples,
        .ImageRead, .AtomicCompareExchange, .AtomicFAddEXT,
        .BitReverse, .BitCount,
        .BitFieldInsert, .BitFieldSExtract, .BitFieldUExtract,
        .GroupNonUniformElect, .GroupNonUniformAll, .GroupNonUniformAny, .GroupNonUniformAllEqual,
        .GroupNonUniformBroadcast, .GroupNonUniformBroadcastFirst,
        .GroupNonUniformBallot,
        .GroupNonUniformIAdd, .GroupNonUniformFAdd,
        .GroupNonUniformIMul, .GroupNonUniformFMul,
        .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin,
        .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax,
        .GroupNonUniformBitwiseAnd, .GroupNonUniformBitwiseOr, .GroupNonUniformBitwiseXor,
        .GroupNonUniformLogicalAnd, .GroupNonUniformLogicalOr,
        .GroupNonUniformShuffle, .GroupNonUniformShuffleXor,
        .GroupNonUniformShuffleUp, .GroupNonUniformShuffleDown,
        .SubgroupAllKHR, .SubgroupAnyKHR,
        => if (words.len > 2) words[2] else null,

        else => null,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    const idx = if (id < module.id_defs.len) module.id_defs[id] orelse return null else return null;
    if (idx >= module.instructions.len) return null;
    return module.instructions[idx];
}

fn getTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(module, id) orelse return null;
    return switch (inst.op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix,
        .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray,
        .TypeStruct, .TypePointer, .TypeFunction,
        => null,
        else => if (inst.words.len > 1) inst.words[1] else null,
    };
}

// ---------------------------------------------------------------------------
// HLSL Emitter
// ---------------------------------------------------------------------------

/// Options for SPIR-V → HLSL cross-compilation.
/// Explicit per-resource HLSL register override (descriptor remap, G6). Maps a
/// SPIR-V (descriptor set, binding) pair to an explicit HLSL register *number*;
/// the register class (b/t/s/u) is still inferred from the resource type. Takes
/// precedence over `binding_shift`. Mirrors spirv-cross's
/// `add_hlsl_resource_binding` for the common single-space case.
pub const ResourceBinding = struct {
    set: u32 = 0,
    binding: u32,
    register: u32,
};

pub const HlslCompileOptions = struct {
    /// Shift all descriptor bindings by this amount. -1 remaps binding=1 → register(b0).
    binding_shift: i32 = 0,
    /// Per-resource register overrides (checked before `binding_shift`).
    resource_bindings: []const ResourceBinding = &.{},
    /// Target HLSL Shader Model version (50 = 5.0, 60 = 6.0).
    shader_model: u32 = 60,
    /// Entry point name to compile (default: "main").
    entry_point_name: []const u8 = "main",
};

/// Resolve the HLSL register number for a resource at (set, binding). If an
/// explicit `resource_bindings` entry matches, its register wins; otherwise
/// `fallback` (the binding-shift-adjusted value computed per call site) is used.
fn resolveHlslRegister(options: HlslCompileOptions, set: u32, binding: u32, fallback: u32) u32 {
    for (options.resource_bindings) |rb| {
        if (rb.set == set and rb.binding == binding) return rb.register;
    }
    return fallback;
}

// HLSL has no native bitfieldExtract/bitfieldInsert, so SPIR-V OpBitField{Insert,
// SExtract,UExtract} are lowered to generated helper functions — verbatim the
// `spvBitfield*` helpers `spirv-cross --hlsl` emits. Each helper is emitted at most once
// (gated by moduleBitfieldNeeds) with the full scalar+vec2/3/4 overload set so HLSL
// overload resolution picks the right width. Insert is uint-based (bit-level insert is
// signedness-agnostic; a signed result is cast back at the call site); UExtract is
// uint-based (zero-extend); SExtract is int-based (sign-extends via the shift trick).
const spv_bitfield_insert_hlsl =
    \\uint spvBitfieldInsert(uint Base, uint Insert, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : (((1u << Count) - 1) << (Offset & 31));
    \\    return (Base & ~Mask) | ((Insert << Offset) & Mask);
    \\}
    \\uint2 spvBitfieldInsert(uint2 Base, uint2 Insert, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : (((1u << Count) - 1) << (Offset & 31));
    \\    return (Base & ~Mask) | ((Insert << Offset) & Mask);
    \\}
    \\uint3 spvBitfieldInsert(uint3 Base, uint3 Insert, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : (((1u << Count) - 1) << (Offset & 31));
    \\    return (Base & ~Mask) | ((Insert << Offset) & Mask);
    \\}
    \\uint4 spvBitfieldInsert(uint4 Base, uint4 Insert, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : (((1u << Count) - 1) << (Offset & 31));
    \\    return (Base & ~Mask) | ((Insert << Offset) & Mask);
    \\}
    \\
    \\
;
const spv_bitfield_uextract_hlsl =
    \\uint spvBitfieldUExtract(uint Base, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : ((1 << Count) - 1);
    \\    return (Base >> Offset) & Mask;
    \\}
    \\uint2 spvBitfieldUExtract(uint2 Base, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : ((1 << Count) - 1);
    \\    return (Base >> Offset) & Mask;
    \\}
    \\uint3 spvBitfieldUExtract(uint3 Base, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : ((1 << Count) - 1);
    \\    return (Base >> Offset) & Mask;
    \\}
    \\uint4 spvBitfieldUExtract(uint4 Base, uint Offset, uint Count)
    \\{
    \\    uint Mask = Count == 32 ? 0xffffffff : ((1 << Count) - 1);
    \\    return (Base >> Offset) & Mask;
    \\}
    \\
    \\
;
const spv_bitfield_sextract_hlsl =
    \\int spvBitfieldSExtract(int Base, int Offset, int Count)
    \\{
    \\    int Mask = Count == 32 ? -1 : ((1 << Count) - 1);
    \\    int Masked = (Base >> Offset) & Mask;
    \\    int ExtendShift = (32 - Count) & 31;
    \\    return (Masked << ExtendShift) >> ExtendShift;
    \\}
    \\int2 spvBitfieldSExtract(int2 Base, int Offset, int Count)
    \\{
    \\    int Mask = Count == 32 ? -1 : ((1 << Count) - 1);
    \\    int2 Masked = (Base >> Offset) & Mask;
    \\    int ExtendShift = (32 - Count) & 31;
    \\    return (Masked << ExtendShift) >> ExtendShift;
    \\}
    \\int3 spvBitfieldSExtract(int3 Base, int Offset, int Count)
    \\{
    \\    int Mask = Count == 32 ? -1 : ((1 << Count) - 1);
    \\    int3 Masked = (Base >> Offset) & Mask;
    \\    int ExtendShift = (32 - Count) & 31;
    \\    return (Masked << ExtendShift) >> ExtendShift;
    \\}
    \\int4 spvBitfieldSExtract(int4 Base, int Offset, int Count)
    \\{
    \\    int Mask = Count == 32 ? -1 : ((1 << Count) - 1);
    \\    int4 Masked = (Base >> Offset) & Mask;
    \\    int ExtendShift = (32 - Count) & 31;
    \\    return (Masked << ExtendShift) >> ExtendShift;
    \\}
    \\
    \\
;

const HlslBitfieldNeeds = struct { insert: bool = false, uextract: bool = false, sextract: bool = false };

/// Scan the module for the three OpBitField* ops so each helper family is emitted once.
fn moduleBitfieldNeeds(m: *const ParsedModule) HlslBitfieldNeeds {
    var r = HlslBitfieldNeeds{};
    for (m.instructions) |inst| {
        switch (inst.op) {
            .BitFieldInsert => r.insert = true,
            .BitFieldSExtract => r.sextract = true,
            .BitFieldUExtract => r.uextract = true,
            else => {},
        }
    }
    return r;
}

pub fn spirvToHLSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: HlslCompileOptions,
) ![]const u8 {
    // G2: recover OpSelectionMerge for unstructured-but-reducible SPIR-V (no-op on
    // structured input; fall back to the original on failure — see spirvToGLSL).
    const _norm = @import("cfg_structurize.zig").structurizeModule(alloc, spirv_words) catch null;
    defer if (_norm) |n| alloc.free(n);
    var module = try parseModule(alloc, _norm orelse spirv_words);
    defer module.deinit(alloc);

    // Descriptor sampler/image ARRAYS (`uniform sampler2D tex[4]`) are not yet
    // supported by the HLSL backend (the Texture/SamplerState split needs the
    // index relocated across both). Fail loud rather than emit broken output —
    // the GLSL backend does support them.
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .UniformConstant) continue;
        const ptr = getDef(&module, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        const pe = getDef(&module, ptr.words[3]) orelse continue;
        if (pe.op == .TypeArray and pe.words.len >= 3) {
            if (getDef(&module, pe.words[2])) |el| {
                if (el.op == .TypeSampledImage or el.op == .TypeSampler or el.op == .TypeImage) return error.UnsupportedSamplerArray;
            }
        }
    }

    // Override entry point if requested
    if (!std.mem.eql(u8, options.entry_point_name, "main")) {
        if (findEntryPoint(&module, options.entry_point_name)) |ep_id| {
            module.entry_point_id = ep_id;
        } else return error.EntryPointNotFound;
    }

    const entry_id = module.entry_point_id orelse return error.NoEntryPoint;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = std.AutoHashMap(u32, []const u8).init(aa);
    defer names.deinit();

    var decorations = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(aa);
    defer decorations.deinit();

    // Phase 1: collect names, decorations
    collectNames(aa, &module, &names);
    // Alias const-initialised Private globals to their promoted const (Design A).
    hlslAliasConstInitializedPrivateVars(aa, &module, &names);

    // Rename HLSL-reserved keyword names (line, register, etc.)
    {
        var it = names.keyIterator();
        while (it.next()) |key_ptr| {
            if (names.get(key_ptr.*)) |n| {
                // HLSL keywords that conflict with common GLSL names or built-in types
                const new_name: ?[]const u8 = if (std.mem.eql(u8, n, "line"))
                    "line_val"
                else if (std.mem.eql(u8, n, "register"))
                    "register_val"
                else if (std.mem.eql(u8, n, "dword"))
                    "dword_val"
                else if (std.mem.eql(u8, n, "Buffer"))
                    "Buffer_val"
                else
                    null;
                if (new_name) |nn| {
                    const renamed = aa.dupe(u8, nn) catch continue;
                    // old.value was allocated by aa (arena allocator), no need to free
                    _ = names.fetchPut(key_ptr.*, renamed) catch null;
                }
            }
        }
    }

    try collectDecorations(aa, &module, &decorations);

    // Phase 2: collect resources
    var cbuffers = std.ArrayList(CbufferDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer cbuffers.deinit(aa);
    var textures = std.ArrayList(TextureDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer textures.deinit(aa);

    collectResources(&module, &names, &decorations, &cbuffers, &textures, aa);

    // Phase 3: emit HLSL
    var output = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    var output_owned = true;
    defer if (output_owned) output.deinit(alloc);
    const w = compat.listWriter(&output, alloc);

    try w.writeAll("// Generated by glslpp SPIR-V -> HLSL cross-compiler\n\n");

    // HLSL has no native bitfield builtins — emit the spvBitfield* helper(s) once for each
    // family actually used (gated by a module scan), then call them at use sites.
    const bf_needs = moduleBitfieldNeeds(&module);
    if (bf_needs.insert) try w.writeAll(spv_bitfield_insert_hlsl);
    if (bf_needs.uextract) try w.writeAll(spv_bitfield_uextract_hlsl);
    if (bf_needs.sextract) try w.writeAll(spv_bitfield_sextract_hlsl);

    // Emit struct forward declarations for types used in cbuffers
    var emitted_structs = std.AutoHashMap(u32, void).init(aa);
    defer emitted_structs.deinit();
    var emitted_names2 = std.StringHashMap(void).init(aa);
    defer emitted_names2.deinit();
    for (cbuffers.items) |cb| {
        hlslEmitStructForwardDecls(&module, &names, cb.type_id, w, aa, &emitted_structs, &emitted_names2) catch {};
    }
    if (emitted_structs.count() > 0) try w.writeAll("\n");

    // Emit cbuffers
    for (cbuffers.items) |cb| {
        var shifted: i32 = @intCast(cb.binding);
        shifted += options.binding_shift;
        if (shifted < 0) shifted = 0;
        const binding: i32 = @intCast(resolveHlslRegister(options, cb.descriptor_set, cb.binding, @intCast(shifted)));
        // SSBO: emit as RWStructuredBuffer (or RasterizerOrdered for interlock)
        if (cb.is_ssbo) {
            // SSBO: emit as RWStructuredBuffer<StructType> or ByteAddressBuffer
            // For shaders with interlock, use RasterizerOrderedByteAddressBuffer
            const has_interlock = blk: {
                for (module.instructions) |inst| {
                    if (inst.op == .BeginInvocationInterlockEXT or inst.op == .EndInvocationInterlockEXT) break :blk true;
                }
                break :blk false;
            };
            // Strip __ssbo_buf__ prefix from the name for emission
            const clean_name = if (std.mem.startsWith(u8, cb.name, "__ssbo_buf__")) cb.name["__ssbo_buf__".len..] else cb.name;
            const uav_binding: u32 = @intCast(binding);
            // If the struct is exactly `{ T data[]; }`, flatten to
            // `RWStructuredBuffer<T>`. HLSL forbids unsized array struct
            // members, so the wrapper would collapse `data` to a scalar.
            if (ssboRuntimeArrayElement(&module, cb.type_id)) |elem_type_id| {
                const elem_name = hlslType(&module, elem_type_id, &names, aa) catch "float";
                if (has_interlock) {
                    try w.print("RasterizerOrderedStructuredBuffer<{s}> {s} : register(u{d});\n\n", .{ elem_name, clean_name, uav_binding });
                } else {
                    try w.print("RWStructuredBuffer<{s}> {s} : register(u{d});\n\n", .{ elem_name, clean_name, uav_binding });
                }
            } else {
                // Emit struct forward declaration for the SSBO struct type
                hlslEmitOneStructForwardDecl(&module, &names, cb.type_id, w, aa, &emitted_structs, &emitted_names2) catch {};
                if (has_interlock) {
                    const struct_name = blk2: {
                        const struct_inst = getDef(&module, cb.type_id);
                        break :blk2 if (struct_inst != null and struct_inst.?.op == .TypeStruct) hlslSafeName(names.get(struct_inst.?.words[1]) orelse "Struct") else "Struct";
                    };
                    try w.print("RasterizerOrderedStructuredBuffer<{s}> {s} : register(u{d});\n\n", .{ struct_name, clean_name, uav_binding });
                } else {
                    const struct_name = blk2: {
                        const struct_inst = getDef(&module, cb.type_id);
                        break :blk2 if (struct_inst != null and struct_inst.?.op == .TypeStruct) names.get(struct_inst.?.words[1]) orelse "Struct" else "Struct";
                    };
                    try w.print("RWStructuredBuffer<{s}> {s} : register(u{d});\n\n", .{ struct_name, clean_name, uav_binding });
                }
            }
        } else {
            try w.print("cbuffer {s} : register(b{d})\n{{\n", .{ cb.name, binding });
            try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa);
            try w.writeAll("};\n\n");
        }
    }

    // Emit textures
    // Detect textures used with Dref operations (need SamplerComparisonState)
    var has_dref_gather = false;
    for (module.instructions) |inst| {
        if (inst.op == .ImageDrefGather) {
            has_dref_gather = true;
            break;
        }
    }

    for (textures.items) |tex| {
        // Resource-binding override wins; otherwise the raw binding (textures
        // historically don't take binding_shift — preserved for compatibility).
        const reg = resolveHlslRegister(options, tex.descriptor_set, tex.binding, tex.binding);
        if (tex.is_storage) {
            // Storage images use UAV register space (u#)
            // For interlock shaders, use RasterizerOrdered variants
            const has_interlock = blk: {
                for (module.instructions) |inst2| {
                    if (inst2.op == .BeginInvocationInterlockEXT or inst2.op == .EndInvocationInterlockEXT) break :blk true;
                }
                break :blk false;
            };
            if (has_interlock) {
                var hlsl_type = tex.hlsl_type;
                if (std.mem.startsWith(u8, hlsl_type, "RW")) hlsl_type = hlsl_type[2..];
                try w.print("RasterizerOrdered{s} {s} : register(u{d});\n", .{ hlsl_type, tex.name, reg });
            } else {
                try w.print("{s} {s} : register(u{d});\n", .{ tex.hlsl_type, tex.name, reg });
            }
        } else {
            try w.print("{s} {s} : register(t{d});\n", .{ tex.hlsl_type, tex.name, reg });
            if (has_dref_gather) {
                try w.print("SamplerComparisonState {s}_sampler : register(s{d});\n", .{ tex.name, reg });
            } else {
                try w.print("SamplerState {s}_sampler : register(s{d});\n", .{ tex.name, reg });
            }
        }
    }
    if (textures.items.len > 0) try w.writeAll("\n");

    // Emit struct declarations for types used as local variables
    var local_structs = std.AutoHashMap(u32, void).init(aa);
    defer local_structs.deinit();
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                const ptr_type = inst.words[1];
                const ptr_inst = getDef(&module, ptr_type) orelse continue;
                if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                    var pointee_id = ptr_inst.words[3];
                    // Unwrap array types to find underlying struct
                    var pt_inst = getDef(&module, pointee_id) orelse continue;
                    while (pt_inst.op == .TypeArray and pt_inst.words.len > 2) {
                        pointee_id = pt_inst.words[2];
                        pt_inst = getDef(&module, pointee_id) orelse break;
                    }
                    if (pt_inst.op == .TypeStruct) {
                        hlslEmitOneStructForwardDecl(&module, &names, pointee_id, w, aa, &local_structs, &emitted_names2) catch {};
                    }
                }
            }
        }
    }
    if (local_structs.count() > 0) try w.writeAll("\n");

    // Find ALL function IDs in the module
    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| {
        if (inst.op == .Function and inst.words.len > 2) {
            try func_ids.append(aa, inst.words[2]);
        }
    }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer {
        var oit = out_param_info.iterator();
        while (oit.next()) |entry| entry.value_ptr.deinit(aa);
        out_param_info.deinit();
    }
    detectOutParams(&module, entry_id, &out_param_info, aa);

    // Emit specialization constants as HLSL [[vk::constant_id(N)]] const declarations.
    // DXC's SPIR-V code path turns these into real OpSpecConstants; for DXIL (pure
    // D3D12) the attribute is ignored and they behave as compile-time constants.
    for (module.instructions) |inst| {
        const is_scalar_sc = inst.op == .SpecConstant and inst.words.len > 3;
        const is_bool_sc = (inst.op == .SpecConstantTrue or inst.op == .SpecConstantFalse) and inst.words.len > 2;
        if (!is_scalar_sc and !is_bool_sc) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try hlslType(&module, type_id, &names, aa);
        const spec_id: ?u32 = blk: {
            const dec_list = decorations.get(result_id) orelse break :blk null;
            for (dec_list.items) |d| {
                if (d.decoration == .spec_id and d.extra.len > 0) break :blk d.extra[0];
            }
            break :blk null;
        };
        const sid = spec_id orelse continue;
        if (is_bool_sc) {
            const bool_val: []const u8 = if (inst.op == .SpecConstantTrue) "true" else "false";
            try w.print("[[vk::constant_id({d})]] const bool {s} = {s};\n", .{ sid, name, bool_val });
        } else {
            const default_val = inst.words[3];
            if (std.mem.eql(u8, type_str, "float")) {
                const fv: f32 = @bitCast(default_val);
                try w.print("[[vk::constant_id({d})]] const {s} {s} = {d};\n", .{ sid, type_str, name, fv });
            } else if (std.mem.eql(u8, type_str, "int")) {
                const iv: i32 = @bitCast(default_val);
                try w.print("[[vk::constant_id({d})]] const {s} {s} = {d};\n", .{ sid, type_str, name, iv });
            } else {
                try w.print("[[vk::constant_id({d})]] const {s} {s} = {d};\n", .{ sid, type_str, name, default_val });
            }
        }
    }
    // OpSpecConstantComposite: assemble the vec/mat from already-declared
    // per-scalar spec consts. `static const vecN <name> = vecN(c0, c1, ...);`
    // DXC's SPIR-V codegen path materialises this back into a real
    // OpSpecConstantComposite; for DXIL the static const is folded at
    // compile time.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantComposite or inst.words.len <= 3) continue;
        const result_id = inst.words[2];
        const name = names.get(result_id) orelse continue;
        const type_id = inst.words[1];
        const type_str = try hlslType(&module, type_id, &names, aa);
        const constituents = inst.words[3..];
        try w.print("static const {s} {s} = {s}(", .{ type_str, name, type_str });
        for (constituents, 0..) |c_id, i| {
            if (i > 0) try w.writeAll(", ");
            const c_name = names.get(c_id) orelse "0";
            try w.writeAll(c_name);
        }
        try w.writeAll(");\n");
    }
    // M3.5: emit OpSpecConstantOp instructions as derived const expressions.
    // DXC's SPIR-V backend re-materialises these into OpSpecConstantOp; for
    // DXIL the expression is folded with the default leaf values.
    for (module.instructions) |inst| {
        if (inst.op != .SpecConstantOp or inst.words.len != 6) continue;
        const type_id = inst.words[1];
        const result_id = inst.words[2];
        const opcode_lit = inst.words[3];
        const name = names.get(result_id) orelse continue;
        const type_str = try hlslType(&module, type_id, &names, aa);
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
        try w.print("static const {s} {s} = {s} {s} {s};\n", .{ type_str, name, op0, op, op1 });
    }
    try w.writeAll("\n");

    // Emit struct declarations for types used in constant composites
    for (module.instructions) |inst| {
        if (inst.op != .ConstantComposite or inst.words.len <= 3) continue;
        const type_id = inst.words[1];
        const type_inst = getDef(&module, type_id) orelse continue;
        if (type_inst.op == .TypeStruct) {
            hlslEmitOneStructForwardDecl(&module, &names, type_id, w, aa, &local_structs, &emitted_names2) catch {};
        } else if (type_inst.op == .TypeArray and type_inst.words.len > 2) {
            const elem_type_id = type_inst.words[2];
            const elem_inst = getDef(&module, elem_type_id) orelse continue;
            if (elem_inst.op == .TypeStruct) {
                hlslEmitOneStructForwardDecl(&module, &names, elem_type_id, w, aa, &local_structs, &emitted_names2) catch {};
            }
        }
    }

    // Emit constant array/struct composites as static const declarations
    for (module.instructions) |inst| {
        if (inst.op != .ConstantComposite or inst.words.len <= 3) continue;
        const rid = inst.words[2];
        const type_id = inst.words[1];
        const type_inst = getDef(&module, type_id) orelse continue;
        // Only handle array and struct types (not vectors which are inlined)
        if (type_inst.op != .TypeArray and type_inst.op != .TypeStruct) continue;
        const name = names.get(rid) orelse continue;
        if (type_inst.op == .TypeArray) {
            // Build full element type string including nested array dimensions
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
            const base_type = try hlslType(&module, elem_id, &names, aa);
            // Build array suffix: [N][M]...
            var arr_suffix = std.ArrayList(u8).initCapacity(aa, 32) catch continue;
            defer arr_suffix.deinit(aa);
            for (dims.items) |d| {
                arr_suffix.print(aa, "[{d}]", .{d}) catch {};
            }
            try w.print("static const {s} {s}{s} = {{", .{ base_type, name, arr_suffix.items });
            for (inst.words[3..], 0..) |comp_id, i| {
                if (i > 0) try w.writeAll(", ");
                const comp_name = names.get(comp_id) orelse "0";
                try w.writeAll(comp_name);
            }
            try w.writeAll("};\n");
        } else if (type_inst.op == .TypeStruct) {
            // static const StructType name = {comp0, comp1, ...}
            const struct_name = names.get(type_id) orelse "Struct";
            try w.print("static const {s} {s} = {{", .{struct_name, name});
            for (inst.words[3..], 0..) |comp_id, i| {
                if (i > 0) try w.writeAll(", ");
                const comp_name = names.get(comp_id) orelse "0";
                try w.writeAll(comp_name);
            }
            try w.writeAll("};\n");
        }
    }
    try w.writeAll("\n");

    // Emit non-entry functions first (user-defined functions)
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue; // emit entry last
        try emitFunction(&module, &names, &decorations, fid, w, aa, false, &out_param_info, options.shader_model);
    }

    // Detect MRT (multiple render targets) for fragment entry
    var mrt_count: u32 = 0;
    if (module.execution_model == .Fragment) {
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) mrt_count += 1;
            }
        }
    }
    if (mrt_count > 1) {
        // Collect and sort output vars by location
        const MRTVar = struct { id: u32, location: u32 };
        var mrt_vars = std.ArrayList(MRTVar).initCapacity(aa, mrt_count) catch return error.OutOfMemory;
        defer mrt_vars.deinit(aa);
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) {
                    const vid = inst.words[2];
                    // Skip builtin outputs
                    const out_builtin = getDecorationValue(&decorations, vid, .built_in);
                    if (out_builtin != null) continue;
                    var loc: u32 = 0;
                    if (decorations.get(vid)) |dec_list| {
                        for (dec_list.items) |d| {
                            if (d.decoration == .location and d.extra.len > 0) {
                                loc = d.extra[0];
                                break;
                            }
                        }
                    }
                    mrt_vars.append(aa, .{ .id = vid, .location = loc }) catch {};
                }
            }
        }
        const MRTSort = struct { fn lessThan(_: void, a: MRTVar, b: MRTVar) bool { return a.location < b.location; } };
        std.sort.insertion(MRTVar, mrt_vars.items, {}, MRTSort.lessThan);
        // Emit the struct with SV_Target semantics
        try w.writeAll("struct _MRT_OUT\n{\n");
        for (mrt_vars.items) |mv| {
            const mv_inst = getDef(&module, mv.id) orelse continue;
            const mv_type = try hlslType(&module, mv_inst.words[1], &names, aa);
            const mv_name = names.get(mv.id) orelse "out";
            try w.print("    {s} {s} : SV_Target{d};\n", .{ mv_type, mv_name, mv.location });
        }
        try w.writeAll("};\n\n");
    }

    // Emit entry function last
    try emitFunction(&module, &names, &decorations, entry_id, w, aa, true, &out_param_info, options.shader_model);
    output_owned = false;
    return output.toOwnedSlice(alloc);
}

const DecorationEntry = struct {
    decoration: spirv.Decoration,
    extra: []const u32,
};

const CbufferDecl = struct {
    name: []const u8,
    type_id: u32,
    binding: u32,
    descriptor_set: u32 = 0,
    is_ssbo: bool = false,
};

const TextureDecl = struct {
    name: []const u8,
    binding: u32,
    descriptor_set: u32 = 0,
    hlsl_type: []const u8,
    is_storage: bool = false,
};

// ---------------------------------------------------------------------------
// Name collection
// ---------------------------------------------------------------------------

fn collectNames(alloc: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    for (module.instructions) |inst| {
        // Collect OpName
        if (inst.op == .Name and inst.words.len >= 3) {
            const id = inst.words[1];
            const name_str = parseLiteralString(alloc, inst.words[2..]) catch continue;
            const sanitized = sanitizeName(alloc, name_str) catch {
                names.put(id, name_str) catch {};
                continue;
            };
            alloc.free(name_str);
            names.put(id, sanitized) catch {};
        }

        // Resolve constants to literal value strings
        if (inst.op == .Constant and inst.words.len > 3) {
            const rid = inst.words[2];
            const type_id = inst.words[1];
            const type_inst = getDef(module, type_id);
            if (type_inst) |ti| {
                const literal = constantLiteral(alloc, ti, inst.words[3..]) catch continue;
                // Free any previous name for this ID
                if (names.fetchPut(rid, literal) catch null) |old| alloc.free(old.value);
                continue;
            }
        }
        if (inst.op == .ConstantTrue and inst.words.len > 2) {
            const lit = alloc.dupe(u8, "true") catch continue;
            if (names.fetchPut(inst.words[2], lit) catch null) |old| alloc.free(old.value);
            continue;
        }
        if (inst.op == .ConstantFalse and inst.words.len > 2) {
            const lit = alloc.dupe(u8, "false") catch continue;
            if (names.fetchPut(inst.words[2], lit) catch null) |old| alloc.free(old.value);
            continue;
        }
        // Resolve ConstantComposite (e.g., vec2(0.5, 0.5))
        if (inst.op == .ConstantComposite and inst.words.len > 3) {
            const rid = inst.words[2];
            const type_id = inst.words[1];
            const type_inst = getDef(module, type_id);
            if (type_inst) |ti| {
                if (ti.op == .TypeVector) {
                    const scalar_type = tryResolveTypeName(module, ti.words[2]);
                    const count = ti.words[3];
                    // Build: typeN(comp0, comp1, ...)
                    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                    defer buf.deinit(alloc);
                    buf.print(alloc, "{s}{d}(", .{scalar_type, count}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf.appendSlice(alloc, ", ") catch continue;
                        const comp_name = names.get(comp_id) orelse "0.0";
                        buf.appendSlice(alloc, comp_name) catch continue;
                    }
                    buf.appendSlice(alloc, ")") catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                }
                // Note: array and struct ConstantComposites get their names from
                // the static const emitter, not here. Their initializer is handled
                // in the Variable handler via resolveInitializer().
            }
        }

        // Auto-name unnamed result IDs
        if (resultIdFromOp(inst.op, inst.words)) |rid| {
            if (!names.contains(rid)) {
                const name = std.fmt.allocPrint(alloc, "v{}", .{counter}) catch continue;
                counter += 1;
                names.put(rid, name) catch {};
            }
        }
    }

    // Deduplicate variable names: if multiple IDs have the same name, append _ID suffix
    // Only deduplicate IDs that are Function-scoped Variables to avoid renaming cbuffer members etc.
    var func_var_ids = std.AutoHashMap(u32, void).init(alloc);
    defer func_var_ids.deinit();
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Function) {
                func_var_ids.put(inst.words[2], {}) catch {};
            }
        }
    }
    // Build reverse map: name -> list of IDs (only for function vars)
    var name_ids = std.StringHashMap(std.ArrayList(u32)).init(alloc);
    defer {
        var it = name_ids.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(alloc);
        }
        name_ids.deinit();
    }
    var fniter = func_var_ids.iterator();
    while (fniter.next()) |entry| {
        const id = entry.key_ptr.*;
        const name = names.get(id) orelse continue;
        const gop = name_ids.getOrPut(name) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u32).initCapacity(alloc, 2) catch continue;
        }
        gop.value_ptr.append(alloc, id) catch {};
    }
    // For names with multiple function-variable IDs, rename to name_ID
    var dniter = name_ids.iterator();
    while (dniter.next()) |entry| {
        const name = entry.key_ptr.*;
        const ids = entry.value_ptr.*;
        if (ids.items.len <= 1) continue;
        for (ids.items, 0..) |id, i| {
            if (i == 0) continue; // Keep first one as-is
            const new_name = std.fmt.allocPrint(alloc, "{s}_{d}", .{ name, id }) catch continue;
            names.put(id, new_name) catch {};
        }
    }
}

fn tryResolveTypeName(module: *const ParsedModule, type_id: u32) []const u8 {
    const inst = getDef(module, type_id) orelse return "float";
    return switch (inst.op) {
        .TypeFloat => "float",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeBool => "bool",
        else => "float",
    };
}

fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    if (type_inst.op == .TypeFloat and literal_words.len > 0) {
        const val: f32 = @bitCast(literal_words[0]);
        // Format float: use 0.5, 1.0 etc but ensure it has a decimal point
        if (val == @floor(val) and @abs(val) < 1e6) {
            const ival: i32 = @intFromFloat(val);
            return std.fmt.allocPrint(alloc, "{d}.0", .{ival});
        }
        return std.fmt.allocPrint(alloc, "{d}", .{val});
    }
    if (type_inst.op == .TypeInt and literal_words.len > 0) {
        const signed = type_inst.words.len > 3 and type_inst.words[3] != 0;
        if (signed) {
            const val: i32 = @bitCast(literal_words[0]);
            return std.fmt.allocPrint(alloc, "{d}", .{val});
        } else {
            return std.fmt.allocPrint(alloc, "{d}u", .{literal_words[0]});
        }
    }
    return std.fmt.allocPrint(alloc, "{d}", .{literal_words[0]});
}

fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, name.len);
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => buf.appendAssumeCapacity(c),
            else => buf.appendAssumeCapacity('_'),
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn parseLiteralString(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
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

// ---------------------------------------------------------------------------
// Decoration collection
// ---------------------------------------------------------------------------

fn collectDecorations(alloc: std.mem.Allocator, module: *const ParsedModule, decorations: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    for (module.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3) {
            const id = inst.words[1];
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            const extra = if (inst.words.len > 3) inst.words[3..] else &[_]u32{};

            const gop = try decorations.getOrPut(id);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(DecorationEntry).empty;
            try gop.value_ptr.append(alloc, .{ .decoration = dec, .extra = extra });
        }
    }
}

fn hasDecoration(decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) bool {
    const list = decorations.get(id) orelse return false;
    for (list.items) |entry| {
        if (entry.decoration == dec) return true;
    }
    return false;
}

fn getDecorationValue(decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decorations.get(id) orelse return null;
    for (list.items) |entry| {
        if (entry.decoration == dec and entry.extra.len > 0) return entry.extra[0];
    }
    return null;
}

fn hasDecorationRaw(decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, raw_val: u32) bool {
    const list = decorations.get(id) orelse return false;
    for (list.items) |entry| {
        if (@intFromEnum(entry.decoration) == raw_val) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Resource collection
// ---------------------------------------------------------------------------

fn collectResources(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    cbuffers: *std.ArrayList(CbufferDecl),
    textures: *std.ArrayList(TextureDecl),
    alloc: std.mem.Allocator,
) void {
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const result_type = inst.words[1];
        const result_id = inst.words[2];
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);

        const ptr_inst = getDef(module, result_type) orelse continue;
        if (ptr_inst.op != .TypePointer or ptr_inst.words.len < 4) continue;
        const pointee_type = ptr_inst.words[3];

        switch (sc) {
            .Uniform, .StorageBuffer => {
                const binding = getDecorationValue(decorations, result_id, .binding) orelse 0;
                const dset = getDecorationValue(decorations, result_id, .descriptor_set) orelse 0;
                const raw_name = names.get(result_id) orelse "Globals";
                // Check if this is an SSBO (BufferBlock decoration on struct type, or StorageBuffer class)
                const is_ssbo = hasDecoration(decorations, pointee_type, .buffer_block) or sc == .StorageBuffer;
                // For SSBO, we need to save the clean name before tagging
                const cb_name: []const u8 = if (is_ssbo) alloc.dupe(u8, raw_name) catch "Globals" else raw_name;
                // Tag SSBO variable name with __ssbo_buf__ prefix so access builders know
                if (is_ssbo) {
                    const tagged = std.fmt.allocPrint(alloc, "__ssbo_buf__{s}", .{raw_name}) catch cb_name;
                    if (names.fetchPut(result_id, tagged) catch null) |old| alloc.free(old.value);
                }
                cbuffers.append(alloc, .{
                    .name = cb_name,
                    .type_id = pointee_type,
                    .binding = binding,
                    .descriptor_set = dset,
                    .is_ssbo = is_ssbo,
                }) catch {};
            },
            .UniformConstant => {
                const pointee_inst = getDef(module, pointee_type) orelse continue;
                const binding = getDecorationValue(decorations, result_id, .binding) orelse 0;
                const dset = getDecorationValue(decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "tex";
                var is_storage = false;
                const hlsl_type = blk: {
                    switch (pointee_inst.op) {
                        .TypeSampledImage => break :blk hlslTextureTypeFromImage(module, pointee_inst.words[2]),
                        .TypeImage => {
                            // Check if this is a storage image (Sampled=2)
                            const img_inst = getDef(module, pointee_type);
                            if (img_inst) |ii| {
                                if (ii.op == .TypeImage and ii.words.len >= 8 and ii.words[7] == 2) {
                                    is_storage = true;
                                }
                            }
                            break :blk hlslTextureTypeFromImage(module, pointee_type);
                        },
                        .TypeSampler => continue, // samplers paired with textures
                        else => continue,
                    }
                };
                textures.append(alloc, .{
                    .name = name,
                    .binding = binding,
                    .descriptor_set = dset,
                    .hlsl_type = hlsl_type,
                    .is_storage = is_storage,
                }) catch {};
            },
            else => {},
        }
    }
}

fn hlslTextureTypeFromImage(module: *const ParsedModule, image_type_id: u32) []const u8 {
    const inst = getDef(module, image_type_id) orelse return "Texture2D";
    if (inst.op != .TypeImage or inst.words.len < 4) return "Texture2D";

    const dim: enum(u32) {
        Dim1D = 0, Dim2D = 1, Dim3D = 2, DimCube = 3, DimBuffer = 5, _,
    } = @enumFromInt(inst.words[3]);

    // OpTypeImage layout: header, result_id, Sampled_Type, Dim, Depth, Arrayed, MS, Sampled, ImageFormat
    const is_arrayed = inst.words.len >= 6 and inst.words[5] == 1;
    const is_ms = inst.words.len >= 7 and inst.words[6] == 1; // Multisampled
    const is_storage = inst.words.len >= 8 and inst.words[7] == 2; // Sampled=2 means storage image

    // Determine component type from Sampled_Type (words[2])
    const is_int: ?enum { int, uint } = blk: {
        const sampled_type_id = inst.words[2];
        const type_inst = getDef(module, sampled_type_id) orelse break :blk null;
        if (type_inst.op == .TypeInt) {
            // OpTypeInt layout: header, result_id, bit_width, signedness (0=unsigned, 1=signed)
            if (type_inst.words.len >= 4 and type_inst.words[3] == 0) break :blk .uint; // unsigned
            break :blk .int; // signed
        }
        break :blk null; // float (default)
    };

    // Storage images use RWTexture/RWBuffer types
    if (is_storage) {
        if (is_int) |int_type| {
            // Use scalar type for single-component formats (R32i/R32ui), vector for multi-component
            const scalar_or_vec: [2][5][]const u8 = .{
                .{ "RWTexture1D<int>", "RWTexture2D<int>", "RWTexture3D<int>", "RWTexture2DArray<int>", "RWBuffer<int>" },
                .{ "RWTexture1D<uint>", "RWTexture2D<uint>", "RWTexture3D<uint>", "RWTexture2DArray<uint>", "RWBuffer<uint>" },
            };
            const int_idx: usize = switch (int_type) { .int => 0, .uint => 1 };
            const dim_idx: usize = switch (dim) {
                .Dim1D => 0, .Dim2D => if (is_arrayed) 3 else 1, .Dim3D => 2,
                .DimBuffer => 4, else => 1,
            };
            return scalar_or_vec[int_idx][dim_idx];
        }
        // Float storage textures
        const rw_float_types = [5][]const u8{
            "RWTexture1D<float4>", "RWTexture2D<float4>", "RWTexture3D<float4>",
            "RWTexture2DArray<float4>", "RWBuffer<float4>",
        };
        const dim_idx: usize = switch (dim) {
            .Dim1D => 0, .Dim2D => if (is_arrayed) 3 else 1, .Dim3D => 2,
            .DimBuffer => 4, else => 1,
        };
        return rw_float_types[dim_idx];
    }

    // MS textures
    if (is_ms) {
        return switch (dim) {
            .Dim2D => if (is_arrayed) "Texture2DMSArray<float4>" else "Texture2DMS<float4>",
            else => "Texture2DMS<float4>",
        };
    }

    // Non-MS: integer textures use template parameter
    if (is_int) |int_type| {
        // Static lookup table to avoid allocation
        const ArrayedDim = enum { d1, d1_arr, d2, d2_arr, cube, cube_arr, d3, buffer };
        const key = switch (dim) {
            .Dim1D => if (is_arrayed) ArrayedDim.d1_arr else ArrayedDim.d1,
            .Dim2D => if (is_arrayed) ArrayedDim.d2_arr else ArrayedDim.d2,
            .DimCube => if (is_arrayed) ArrayedDim.cube_arr else ArrayedDim.cube,
            .Dim3D => ArrayedDim.d3,
            .DimBuffer => ArrayedDim.buffer,
            else => ArrayedDim.d2,
        };
        const int_types = [2][8][]const u8{
            .{ "Texture1D<int4>", "Texture1DArray<int4>", "Texture2D<int4>", "Texture2DArray<int4>", "TextureCube<int4>", "TextureCubeArray<int4>", "Texture3D<int4>", "Buffer<int4>" },
            .{ "Texture1D<uint4>", "Texture1DArray<uint4>", "Texture2D<uint4>", "Texture2DArray<uint4>", "TextureCube<uint4>", "TextureCubeArray<uint4>", "Texture3D<uint4>", "Buffer<uint4>" },
        };
        const int_idx: usize = switch (int_type) { .int => 0, .uint => 1 };
        const dim_idx: usize = @intFromEnum(key);
        return int_types[int_idx][dim_idx];
    }

    return switch (dim) {
        .Dim1D => if (is_arrayed) "Texture1DArray<float4>" else "Texture1D<float4>",
        .Dim2D => if (is_arrayed) "Texture2DArray<float4>" else "Texture2D<float4>",
        .DimCube => if (is_arrayed) "TextureCubeArray<float4>" else "TextureCube<float4>",
        .Dim3D => "Texture3D<float4>",
        .DimBuffer => "Buffer<float4>",
        else => "Texture2D<float4>",
    };
}

/// True when the image VALUE `id` resolves to a multisampled OpTypeImage (the
/// MS operand, `words[6]`, is 1). `Texture2DMS`/`Texture2DMSArray.GetDimensions`
/// requires an extra `NumberOfSamples` out-param, so the image-size query must
/// emit one more argument for these types. Resolves the value's result type
/// (`words[1]`) and unwraps an OpTypeSampledImage. OpTypeImage layout:
/// `[op, result_id, sampled_type, DIM, DEPTH, ARRAYED, MS, sampled, format]`.
fn imageValueIsMultisampled(module: *const ParsedModule, image_value_id: u32) bool {
    const vdef = getDef(module, image_value_id) orelse return false;
    if (vdef.words.len < 2) return false;
    var tinst = getDef(module, vdef.words[1]) orelse return false;
    if (tinst.op == .TypeSampledImage and tinst.words.len > 2) {
        tinst = getDef(module, tinst.words[2]) orelse return false;
    }
    if (tinst.op != .TypeImage or tinst.words.len < 7) return false;
    return tinst.words[6] == 1;
}

// ---------------------------------------------------------------------------
// Type resolution
// ---------------------------------------------------------------------------

fn hlslGetArraySuffix(module: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    return common.commonGetArraySuffix(module.instructions, module.id_defs, ptr_type_id, true);
}

fn hlslType(module: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, type_id) orelse return "float4";
    switch (inst.op) {
        .TypeVoid => return "void",
        .TypeBool => return "bool",
        .TypeInt => {
            const signed = inst.words.len > 3 and inst.words[3] != 0;
            return if (signed) "int" else "uint";
        },
        .TypeFloat => return if (inst.words.len > 2 and inst.words[2] == 16) "half" else "float",
        .TypeVector => {
            const scalar = try hlslType(module, inst.words[2], names, alloc);
            const cols = inst.words[3];
            // Fast path for common types (avoid allocation)
            if (std.mem.eql(u8, scalar, "float")) {
                const names_vec = [_][]const u8{ "", "float", "float2", "float3", "float4" };
                if (cols >= 1 and cols <= 4) return names_vec[cols];
            } else if (std.mem.eql(u8, scalar, "half")) {
                const names_vec = [_][]const u8{ "", "half", "half2", "half3", "half4" };
                if (cols >= 1 and cols <= 4) return names_vec[cols];
            } else if (std.mem.eql(u8, scalar, "int")) {
                const names_vec = [_][]const u8{ "", "int", "int2", "int3", "int4" };
                if (cols >= 1 and cols <= 4) return names_vec[cols];
            } else if (std.mem.eql(u8, scalar, "uint")) {
                const names_vec = [_][]const u8{ "", "uint", "uint2", "uint3", "uint4" };
                if (cols >= 1 and cols <= 4) return names_vec[cols];
            } else if (std.mem.eql(u8, scalar, "bool")) {
                const names_vec = [_][]const u8{ "", "bool", "bool2", "bool3", "bool4" };
                if (cols >= 1 and cols <= 4) return names_vec[cols];
            }
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ scalar, cols });
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const col_type = getDef(module, inst.words[2]);
            const rows: u32 = if (col_type) |ct| ct.words[3] else cols;
            // Fast path for common matrix types (avoid allocation)
            const mat_names = [_]struct { c: u32, r: u32, n: []const u8 }{
                .{ .c = 2, .r = 2, .n = "float2x2" },
                .{ .c = 2, .r = 3, .n = "float2x3" },
                .{ .c = 2, .r = 4, .n = "float2x4" },
                .{ .c = 3, .r = 2, .n = "float3x2" },
                .{ .c = 3, .r = 3, .n = "float3x3" },
                .{ .c = 3, .r = 4, .n = "float3x4" },
                .{ .c = 4, .r = 2, .n = "float4x2" },
                .{ .c = 4, .r = 3, .n = "float4x3" },
                .{ .c = 4, .r = 4, .n = "float4x4" },
            };
            for (mat_names) |mn| {
                if (mn.c == cols and mn.r == rows) return mn.n;
            }
            return std.fmt.allocPrint(alloc, "float{d}x{d}", .{ cols, rows });
        },
        .TypeArray => return try hlslType(module, inst.words[2], names, alloc),
        .TypeRuntimeArray => return try hlslType(module, inst.words[2], names, alloc),
        .TypePointer => {
            if (inst.words.len > 3) return try hlslType(module, inst.words[3], names, alloc);
            return "float4";
        },
        .TypeStruct => return hlslSafeName(names.get(type_id) orelse "Struct"),
        else => return "float4",
    }
}

// ---------------------------------------------------------------------------
// Struct forward declarations for types used in cbuffers
// ---------------------------------------------------------------------------

fn hlslEmitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitStructForwardDecls(module, names, root_type_id, w, alloc, emitted, emitted_names, hlslType, hlslGetMemberName);
}

fn hlslEmitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    // Use common implementation but apply hlslSafeName to the struct name
    const instructions = module.instructions;
    const id_defs = module.id_defs;
    const inst = common.localGetDef(instructions, id_defs, type_id) orelse return;
    if (inst.op != .TypeStruct) return;

    // Recurse into member types first
    if (inst.words.len > 2) {
        for (inst.words[2..]) |mt_id| {
            try hlslEmitOneStructForwardDecl(module, names, mt_id, w, alloc, emitted, emitted_names);
        }
    }

    if (emitted.get(type_id) != null) return;
    const raw_name = names.get(type_id) orelse "Struct";
    const sname = hlslSafeName(raw_name);
    if (emitted_names.get(sname) != null) return;
    emitted.put(type_id, {}) catch return;
    try emitted_names.put(sname, {});

    try w.print("struct {s}\n{{\n", .{sname});
    for (inst.words[2..], 0..) |mt_id, mi| {
        const mti = common.localGetDef(instructions, id_defs, mt_id);
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const et = try hlslType(module, mi2.words[2], names, alloc);
                const li = common.localGetDef(instructions, id_defs, mi2.words[3]);
                const lv: u32 = if (li) |l| l.words[3] else 1;
                var mname_buf: [32]u8 = undefined;
                const mname = hlslGetMemberName(module, type_id, @intCast(mi), &mname_buf);
                try w.print("    {s} {s}[{d}];\n", .{ et, mname, lv });
                continue;
            }
        }
        const member_type = try hlslType(module, mt_id, names, alloc);
        var mname_buf: [32]u8 = undefined;
        const mname = hlslGetMemberName(module, type_id, @intCast(mi), &mname_buf);
        try w.print("    {s} {s};\n", .{ member_type, mname });
    }
    try w.writeAll("};\n\n");
}

// ---------------------------------------------------------------------------
// Struct member emission
// ---------------------------------------------------------------------------

fn emitStructMembers(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_type_id: u32, cbuffer_name: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const inst = getDef(module, struct_type_id) orelse return;
    if (inst.op != .TypeStruct) return;

    for (inst.words[2..], 0..) |member_type_id, member_idx| {
        const member_type = try hlslType(module, member_type_id, names, alloc);

        // Get member name from OpMemberName, fallback to _m{index}
        var mname_buf: [32]u8 = undefined;
        const mname = hlslGetMemberName(module, struct_type_id, @intCast(member_idx), &mname_buf);

        // Check for array
        const mt_inst = getDef(module, member_type_id);

        // A row_major matrix member's std140 bytes are the row-major layout of
        // the logical matrix M. glslpp stores a cbuffer matrix as M (its
        // mul(M,v) convention requires it), so HLSL must read these bytes with
        // the `row_major` storage qualifier to reconstruct M. ColMajor stays
        // bare (HLSL's default is column_major). This is the OPPOSITE keyword to
        // spirv-cross, whose convention is the transpose of glslpp's. Reject
        // non-square row_major (needs swapped dims we don't yet emit) — honest
        // error over silent-wrong. The matrix type id is the member type itself
        // or, for an array-of-matrix member, the element type.
        const matrix_tid: ?u32 = blk: {
            if (mt_inst) |mi| {
                if (mi.op == .TypeMatrix) break :blk member_type_id;
                if (mi.op == .TypeArray and mi.words.len > 3) {
                    const et = getDef(module, mi.words[2]);
                    if (et != null and et.?.op == .TypeMatrix) break :blk mi.words[2];
                }
            }
            break :blk null;
        };
        const row_major_qual: []const u8 = blk: {
            if (matrix_tid) |mtid| {
                if (memberIsRowMajor(module, struct_type_id, @intCast(member_idx))) {
                    if (matrixIsNonSquare(module, mtid)) return error.UnsupportedRowMajorMatrix;
                    break :blk "row_major ";
                }
            }
            break :blk "";
        };

        if (mt_inst) |mi| {
            if (mi.op == .TypeArray and mi.words.len > 3) {
                const elem_type = try hlslType(module, mi.words[2], names, alloc);
                const len_id = mi.words[3];
                const len_inst = getDef(module, len_id);
                const len_val: u32 = if (len_inst) |li| li.words[3] else 1;
                try w.print("    {s}{s} {s}_{s}[{d}];\n", .{ row_major_qual, elem_type, cbuffer_name, mname, len_val });
                continue;
            }
        }
        try w.print("    {s}{s} {s}_{s};\n", .{ row_major_qual, member_type, cbuffer_name, mname });
    }
}

// ---------------------------------------------------------------------------
// Function emission
// ---------------------------------------------------------------------------

/// Detect out-parameters by scanning function calls in the entry function.
/// If a call passes an Output storage class variable as an argument,
/// that parameter position is recorded as out for the called function.
fn detectOutParams(
    module: *const ParsedModule,
    entry_id: u32,
    out_param_info: *std.AutoHashMap(u32, std.ArrayList(usize)),
    alloc: std.mem.Allocator,
) void {
    const func_idx = if (entry_id < module.id_defs.len) module.id_defs[entry_id] orelse return else return;

    // Collect all Output storage class variable IDs
    var output_vars = std.AutoHashMap(u32, void).init(alloc);
    defer output_vars.deinit();
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output) {
                output_vars.put(inst.words[2], {}) catch {};
            }
        }
    }

    // Also check loads from Output variables — these get aliased to the var name
    // In our backend, loads from Output vars are aliased to the var name directly.
    // So we also need to check if a Load result was aliased from an Output var.
    // Build a map: load_result_id → was_from_output
    var load_from_output = std.AutoHashMap(u32, void).init(alloc);
    defer load_from_output.deinit();
    {
        var scan_idx: usize = 0;
        while (scan_idx < module.instructions.len) : (scan_idx += 1) {
            const inst = module.instructions[scan_idx];
            if (inst.op == .Load and inst.words.len >= 4) {
                const ptr_id = inst.words[3];
                if (output_vars.contains(ptr_id)) {
                    load_from_output.put(inst.words[2], {}) catch {};
                }
            }
        }
    }

    // Scan entry function body for FunctionCall instructions
    var idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op != .FunctionCall or inst.words.len < 4) continue;

        const called_func_id = inst.words[3];
        // For each argument, check if it's an Output variable or a load of one
        for (inst.words[4..], 0..) |arg_id, param_idx| {
            if (output_vars.contains(arg_id) or load_from_output.contains(arg_id)) {
                const gop = out_param_info.getOrPut(called_func_id) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(usize).initCapacity(alloc, 4) catch continue;
                }
                gop.value_ptr.append(alloc, param_idx) catch {};
            }
        }
    }
}

/// Returns the HLSL semantic to use for `gl_Position` in the vertex-shader
/// output struct: `POSITION` for Shader Model < 6.0 (HLSL 5.x / D3D11
/// down-compile path) and `SV_Position` for SM 6.0+. (M5.1)
fn posSemantic(shader_model: u32) []const u8 {
    return if (shader_model < 60) "POSITION" else "SV_Position";
}

fn emitFunction(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    is_entry: bool,
    out_param_info: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    shader_model: u32,
) !void {
    const func_inst = getDef(module, func_id) orelse return;
    if (func_inst.op != .Function or func_inst.words.len < 5) return;

    const func_type_id = func_inst.words[4];
    const func_type_inst = getDef(module, func_type_id) orelse return;
    const return_type_id = func_type_inst.words[2];
    const return_type = try hlslType(module, return_type_id, names, alloc);
    const is_fragment = is_entry and module.execution_model == .Fragment;

    // Find output and input variables for fragment shader entry
    var output_var_id: ?u32 = null;
    var input_var_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer input_var_ids.deinit(alloc);
    // Collect ALL output variables (for MRT support)
    const OutputVar = struct { id: u32, location: u32 };
    var output_vars = std.ArrayList(OutputVar).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer output_vars.deinit(alloc);
    // Collect builtin output variables (e.g., gl_SampleMask)
    var builtin_output_ids = std.ArrayList(u32).initCapacity(alloc, 2) catch return error.OutOfMemory;
    defer builtin_output_ids.deinit(alloc);
    if (is_fragment) {
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) {
                    const vid = inst.words[2];
                    // Skip builtin outputs — they get special handling
                    const out_builtin = getDecorationValue(decorations, vid, .built_in);
                    if (out_builtin != null) {
                        builtin_output_ids.append(alloc, vid) catch {};
                        continue;
                    }
                    // Find location decoration
                    var loc: u32 = 0;
                    if (decorations.get(vid)) |dec_list| {
                        for (dec_list.items) |d| {
                            if (d.decoration == .location and d.extra.len > 0) {
                                loc = d.extra[0];
                                break;
                            }
                        }
                    }
                    output_vars.append(alloc, .{ .id = vid, .location = loc }) catch {};
                } else if (sc == .Input) {
                    input_var_ids.append(alloc, inst.words[2]) catch {};
                }
            }
        }
        // Sort output vars by location
        const SortCtx = struct {
            fn lessThan(_: void, a: OutputVar, b: OutputVar) bool {
                return a.location < b.location;
            }
        };
        std.sort.insertion(OutputVar, output_vars.items, {}, SortCtx.lessThan);
        if (output_vars.items.len > 0) {
            output_var_id = output_vars.items[0].id; // primary output (location 0)
        }
    }

    // Collect function parameters
    const func_idx = if (func_id < module.id_defs.len) module.id_defs[func_id] orelse return else return;
    const func_name = names.get(func_id) orelse "func";

    var param_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer param_ids.deinit(alloc);

    var idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionParameter) {
            try param_ids.append(alloc, inst.words[2]);
        } else if (inst.op != .Label) {
            break;
        }
    }

    // Detect out-parameter pattern: Variable + Store(param_id, value)
    // When a function parameter is immediately stored into a local variable,
    // it indicates an out/inout parameter from the GLSL source.
    // We map the param name to the local variable and add 'out' qualifier.
    var out_param_var_ids = std.AutoHashMap(u32, u32).init(alloc); // param_id → var_id
    var out_param_skip_vars = std.AutoHashMap(u32, void).init(alloc); // var_id to skip in body
    defer out_param_var_ids.deinit();
    defer out_param_skip_vars.deinit();
    {
        var scan_idx = func_idx + 1;
        while (scan_idx < module.instructions.len) : (scan_idx += 1) {
            const scan_inst = module.instructions[scan_idx];
            if (scan_inst.op == .FunctionEnd) break;
            if (scan_inst.op == .Label) continue;
            if (scan_inst.op == .FunctionParameter) continue;
            // Look for Variable (Function storage class) followed by Store
            if (scan_inst.op == .Variable and scan_inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(scan_inst.words[3]);
                if (sc == .Function) {
                    const var_id = scan_inst.words[2];
                    // Check if next instruction is Store to this var from a param
                    if (scan_idx + 1 < module.instructions.len) {
                        const next = module.instructions[scan_idx + 1];
                        if (next.op == .Store and next.words.len >= 3 and next.words[1] == var_id) {
                            const stored_val = next.words[2];
                            // Check if stored value is one of the params
                            for (param_ids.items) |pid| {
                                if (pid == stored_val) {
                                    out_param_var_ids.put(pid, var_id) catch {};
                                    out_param_skip_vars.put(var_id, {}) catch {};
                                    // Alias: the param name should resolve to the var
                                    const pname = names.get(pid) orelse "p";
                                    const palias = alloc.dupe(u8, pname) catch continue;
                                    if (names.fetchPut(var_id, palias) catch null) |old| alloc.free(old.value);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (scan_inst.op != .Variable and scan_inst.op != .Store) break;
        }
    }

    // Phase 2: For params detected as out via call-site analysis (out_param_info),
    // find the first Function-scoped Variable with matching type and alias it.
    // This handles the case where DCE removed the initial Variable+Store(param) copy.
    if (out_param_info.get(func_id)) |out_indices| {
        for (out_indices.items) |param_idx| {
            if (param_idx >= param_ids.items.len) continue;
            const pid = param_ids.items[param_idx];
            if (out_param_var_ids.contains(pid)) continue; // already handled above

            const p_inst = getDef(module, pid) orelse continue;
            const param_type_id = p_inst.words[1]; // type of the FunctionParameter

            // Find the first Function-scoped Variable whose type matches
            var scan_idx2 = func_idx + 1;
            while (scan_idx2 < module.instructions.len) : (scan_idx2 += 1) {
                const si = module.instructions[scan_idx2];
                if (si.op == .FunctionEnd) break;
                if (si.op != .Variable or si.words.len < 4) continue;
                const sc: spirv.StorageClass = @enumFromInt(si.words[3]);
                if (sc != .Function) continue;

                const var_id = si.words[2];
                // The Variable's type is a pointer; check if pointee matches param type
                const var_type_inst = getDef(module, si.words[1]);
                if (var_type_inst) |vti| {
                    if (vti.op == .TypePointer and vti.words.len > 3) {
                        if (vti.words[3] == param_type_id) {
                            // Match! Alias this variable to the param name
                            out_param_var_ids.put(pid, var_id) catch {};
                            out_param_skip_vars.put(var_id, {}) catch {};
                            const pname = names.get(pid) orelse "p";
                            const palias = alloc.dupe(u8, pname) catch continue;
                            if (names.fetchPut(var_id, palias) catch null) |old| alloc.free(old.value);
                            break;
                        }
                    }
                }
            }
        }
    }

    // Emit signature
    const is_compute = is_entry and module.execution_model == .GLCompute;
    const is_mesh = is_entry and module.execution_model == .MeshEXT;
    const is_task = is_entry and module.execution_model == .TaskEXT;
    const is_raygen = is_entry and module.execution_model == .RayGenerationKHR;
    const is_closesthit = is_entry and module.execution_model == .ClosestHitKHR;
    const is_miss = is_entry and module.execution_model == .MissKHR;
    const is_intersection = is_entry and module.execution_model == .IntersectionKHR;
    const is_anyhit = is_entry and module.execution_model == .AnyHitKHR;
    const is_callable = is_entry and module.execution_model == .CallableKHR;
    const is_rt = is_raygen or is_closesthit or is_miss or is_intersection or is_anyhit or is_callable;
    const is_vertex = is_entry and module.execution_model == .Vertex;

    // -------------------------------------------------------------------------
    // Vertex stage: emit VS_INPUT / VS_OUTPUT structs and route Input/Output
    // SPIR-V variables through them. (M5.0)
    //
    // Strategy: collect all `Input` and `Output` storage-class globals, then
    // rewrite their entries in the `names` map to `input.<orig>` /
    // `output.<orig>` BEFORE body emission. Existing OpLoad/OpStore code paths
    // resolve through `names`, so the body naturally produces the desired
    // routed expressions without needing to rewrite every Load/Store opcode.
    // -------------------------------------------------------------------------
    const VtxField = struct {
        id: u32,
        orig_name: []const u8,
        type_id: u32,
        location: ?u32,
        builtin: ?u32,
    };
    var vtx_inputs = std.ArrayList(VtxField).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer vtx_inputs.deinit(alloc);
    var vtx_outputs = std.ArrayList(VtxField).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer vtx_outputs.deinit(alloc);
    if (is_vertex) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .Input and sc != .Output) continue;
            const vid = inst.words[2];
            const pointee = resolvePointeeType(module, vid) orelse continue;
            const orig = names.get(vid) orelse "var";
            const builtin = getDecorationValue(decorations, vid, .built_in);
            const loc = getDecorationValue(decorations, vid, .location);
            // Skip per-vertex interface blocks (gl_PerVertex etc.) — out of scope for v1.
            // These appear as struct-typed Input/Output. Bare scalars/vectors and
            // builtins with known semantics are handled.
            const pt_inst = getDef(module, pointee);
            if (pt_inst) |pi| {
                if (pi.op == .TypeStruct) continue;
            }
            const field = VtxField{
                .id = vid,
                .orig_name = orig,
                .type_id = pointee,
                .location = loc,
                .builtin = builtin,
            };
            if (sc == .Input) {
                vtx_inputs.append(alloc, field) catch {};
            } else {
                vtx_outputs.append(alloc, field) catch {};
            }
        }
        // Sort inputs/outputs by location (built-ins last; they don't have one).
        const SortCtx = struct {
            fn lessThan(_: void, a: VtxField, b: VtxField) bool {
                const al = a.location orelse std.math.maxInt(u32);
                const bl = b.location orelse std.math.maxInt(u32);
                return al < bl;
            }
        };
        std.sort.insertion(VtxField, vtx_inputs.items, {}, SortCtx.lessThan);
        std.sort.insertion(VtxField, vtx_outputs.items, {}, SortCtx.lessThan);

        // Emit VS_INPUT struct.
        try w.writeAll("struct VS_INPUT\n{\n");
        for (vtx_inputs.items) |fld| {
            var tname = try hlslType(module, fld.type_id, names, alloc);
            const semantic: []const u8 = if (fld.builtin) |b| blk: {
                const bi: spirv.BuiltIn = @enumFromInt(b);
                break :blk switch (bi) {
                    .vertex_id, .vertex_index => @as([]const u8, "SV_VertexID"),
                    .instance_id, .instance_index => @as([]const u8, "SV_InstanceID"),
                    else => @as([]const u8, "TEXCOORD0"),
                };
            } else "TEXCOORD0";
            // dxc requires SV_VertexID / SV_InstanceID to be `uint`, but glslang
            // types gl_VertexIndex / gl_InstanceIndex as signed int. Force uint
            // here (the body's int uses convert implicitly) — else dxc rejects
            // ("SV_VertexID must be uint"), a silent-wrong output.
            if (fld.builtin) |b| {
                const bi: spirv.BuiltIn = @enumFromInt(b);
                switch (bi) {
                    .vertex_id, .vertex_index, .instance_id, .instance_index => tname = "uint",
                    else => {},
                }
            }
            if (fld.builtin != null) {
                try w.print("    {s} {s} : {s};\n", .{ tname, fld.orig_name, semantic });
            } else {
                try w.print("    {s} {s} : TEXCOORD{d};\n", .{ tname, fld.orig_name, fld.location orelse 0 });
            }
        }
        try w.writeAll("};\n\n");

        // Emit VS_OUTPUT struct.
        try w.writeAll("struct VS_OUTPUT\n{\n");
        for (vtx_outputs.items) |fld| {
            const tname = try hlslType(module, fld.type_id, names, alloc);
            if (fld.builtin) |b| {
                const bi: spirv.BuiltIn = @enumFromInt(b);
                const semantic: []const u8 = switch (bi) {
                    .position => posSemantic(shader_model),
                    else => continue, // unsupported vertex output builtin (gl_PointSize, gl_ClipDistance, ...) — TODO
                };
                try w.print("    {s} {s} : {s};\n", .{ tname, fld.orig_name, semantic });
            } else {
                try w.print("    {s} {s} : TEXCOORD{d};\n", .{ tname, fld.orig_name, fld.location orelse 0 });
            }
        }
        try w.writeAll("};\n\n");

        // Rewrite Input/Output names to `input.<orig>` / `output.<orig>` so
        // body emission naturally produces the routed expressions. Skip
        // unsupported output builtins so they keep their old name (the body
        // will still write to a now-undeclared global, but that's a known
        // v1 deferral path covered by the TODO above).
        for (vtx_inputs.items) |fld| {
            const new_name = try std.fmt.allocPrint(alloc, "input.{s}", .{fld.orig_name});
            if (try names.fetchPut(fld.id, new_name)) |old| alloc.free(old.value);
        }
        for (vtx_outputs.items) |fld| {
            if (fld.builtin) |b| {
                const bi: spirv.BuiltIn = @enumFromInt(b);
                switch (bi) {
                    .position => {},
                    else => continue,
                }
            }
            const new_name = try std.fmt.allocPrint(alloc, "output.{s}", .{fld.orig_name});
            if (try names.fetchPut(fld.id, new_name)) |old| alloc.free(old.value);
        }
    }

    if (is_compute or is_task) {
        try w.print("[numthreads({d}, {d}, {d})]\n", .{
            module.local_size[0],
            module.local_size[1],
            module.local_size[2],
        });
    }
    // -------------------------------------------------------------------------
    // Mesh stage: emit `struct VertexOut` (and optional `struct PrimOut`) so
    // the entry-point signature can reference them. (M5.2 v2.a / v2.b)
    //
    // Per-vertex outputs go into `VertexOut`; outputs decorated `PerPrimitiveEXT`
    // go into `PrimOut`. We always seed `VertexOut` with a `gl_Position :
    // SV_Position` field because DXC requires every mesh per-vertex output
    // element to carry a position. Body store routing (v2.c) is out of scope
    // for the M5.2 v2 baseline — the test contract only checks signature shape.
    // -------------------------------------------------------------------------
    const MeshField = struct {
        id: u32,
        orig_name: []const u8,
        elem_type_id: u32,
        location: ?u32,
    };
    var mesh_vtx_fields = std.ArrayList(MeshField).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer mesh_vtx_fields.deinit(alloc);
    var mesh_prim_fields = std.ArrayList(MeshField).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer mesh_prim_fields.deinit(alloc);

    if (is_mesh) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .Output) continue;
            const vid = inst.words[2];
            // Skip built-ins (Position etc.) — gl_Position is injected explicitly.
            if (getDecorationValue(decorations, vid, .built_in) != null) continue;
            // Skip the synthetic mesh-builtin arrays: they don't go into
            // VertexOut/PrimOut as user fields. v2.c routes their stores
            // through the signature parameters directly (see name-rewrite
            // pass below).
            //  - gl_MeshPerVertexEXT       → verts[i].gl_Position (the
            //    VertexOut seed field). Adding it again would duplicate
            //    the gl_Position element with a redundant COLOR<N> field.
            //  - gl_Primitive{Triangle,Line,Point}IndicesEXT → flat
            //    `out indices` signature parameter; never a VertexOut /
            //    PrimOut struct member.
            const orig = names.get(vid) orelse "var";
            if (isMeshBuiltinName(orig)) continue;
            // Mesh outputs are GLSL arrays implicitly sized to max_vertices /
            // max_primitives — they materialise in SPIR-V as either
            // TypeArray (sized) or TypeRuntimeArray (unsized).
            const pointee = resolvePointeeType(module, vid) orelse continue;
            const pt_inst = getDef(module, pointee) orelse continue;
            var elem_type_id: u32 = 0;
            if (pt_inst.op == .TypeArray and pt_inst.words.len > 2) {
                elem_type_id = pt_inst.words[2];
            } else if (pt_inst.op == .TypeRuntimeArray and pt_inst.words.len > 2) {
                elem_type_id = pt_inst.words[2];
            } else {
                continue;
            }
            const loc = getDecorationValue(decorations, vid, .location);
            const fld = MeshField{
                .id = vid,
                .orig_name = orig,
                .elem_type_id = elem_type_id,
                .location = loc,
            };
            if (hasDecoration(decorations, vid, .per_primitive_ext)) {
                mesh_prim_fields.append(alloc, fld) catch {};
            } else {
                mesh_vtx_fields.append(alloc, fld) catch {};
            }
        }
        // Stable sort by location (no location → last).
        const MeshSort = struct {
            fn lessThan(_: void, a: MeshField, b: MeshField) bool {
                const al = a.location orelse std.math.maxInt(u32);
                const bl = b.location orelse std.math.maxInt(u32);
                return al < bl;
            }
        };
        std.sort.insertion(MeshField, mesh_vtx_fields.items, {}, MeshSort.lessThan);
        std.sort.insertion(MeshField, mesh_prim_fields.items, {}, MeshSort.lessThan);

        // Emit `struct VertexOut`. Always include `gl_Position : SV_Position`
        // as the first field (DXC requires it on the per-vertex output element).
        try w.writeAll("struct VertexOut\n{\n");
        try w.print("    float4 gl_Position : {s};\n", .{posSemantic(shader_model)});
        for (mesh_vtx_fields.items, 0..) |fld, i| {
            const tname = try hlslType(module, fld.elem_type_id, names, alloc);
            // Use COLOR<N> for arbitrary per-vertex user data — matches
            // spirv-cross / fxc convention and keeps DXC happy.
            try w.print("    {s} {s} : COLOR{d};\n", .{ tname, fld.orig_name, i });
        }
        try w.writeAll("};\n\n");

        // Emit `struct PrimOut` only when at least one per-primitive output
        // exists. Empty struct is invalid HLSL and DXC complains.
        if (mesh_prim_fields.items.len > 0) {
            try w.writeAll("struct PrimOut\n{\n");
            for (mesh_prim_fields.items, 0..) |fld, i| {
                const tname = try hlslType(module, fld.elem_type_id, names, alloc);
                try w.print("    {s} {s} : COLOR{d};\n", .{ tname, fld.orig_name, i });
            }
            try w.writeAll("};\n\n");
        }

        // -------------------------------------------------------------------
        // M5.2 v2.c — body store routing.
        //
        // The mesh body emits stores against access chains whose base is
        // one of:
        //   - gl_MeshPerVertexEXT[i]            (synthetic per-vertex array
        //                                        of vec4 — the gl_Position
        //                                        element of VertexOut)
        //   - gl_Primitive*IndicesEXT[i]        (flat per-primitive index
        //                                        array — uint/uint2/uint3)
        //   - <user>[i]                          (per-vertex output, location N)
        //   - <user>[i]                          (perprimitiveEXT, location N)
        //
        // None of those names are HLSL identifiers in scope inside the
        // entry point. Rewrite the corresponding `names` entries to a
        // sentinel `__mesh_route__<base>[.<member>]` so writeAccessExpr /
        // buildAccessExpr can route the store through the signature
        // parameter (verts / prims / prims_data).
        // -------------------------------------------------------------------
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .Output) continue;
            const vid = inst.words[2];
            if (getDecorationValue(decorations, vid, .built_in) != null) continue;
            const orig = names.get(vid) orelse continue;
            const route_name: []const u8 = blk: {
                if (std.mem.eql(u8, orig, "gl_MeshPerVertexEXT")) {
                    break :blk try alloc.dupe(u8, "__mesh_route__verts.gl_Position");
                }
                if (std.mem.eql(u8, orig, "gl_PrimitiveTriangleIndicesEXT") or
                    std.mem.eql(u8, orig, "gl_PrimitiveLineIndicesEXT") or
                    std.mem.eql(u8, orig, "gl_PrimitivePointIndicesEXT"))
                {
                    break :blk try alloc.dupe(u8, "__mesh_route__prims");
                }
                if (hasDecoration(decorations, vid, .per_primitive_ext)) {
                    break :blk try std.fmt.allocPrint(alloc, "__mesh_route__prims_data.{s}", .{orig});
                }
                // User per-vertex output → verts[i].<orig>
                break :blk try std.fmt.allocPrint(alloc, "__mesh_route__verts.{s}", .{orig});
            };
            if (try names.fetchPut(vid, route_name)) |old| alloc.free(old.value);
        }

        try w.print("[numthreads({d}, {d}, {d})]\n", .{
            module.local_size[0],
            module.local_size[1],
            module.local_size[2],
        });
        const topo_str: []const u8 = if (module.mesh_topology) |t| switch (t) {
            .triangles => "triangle",
            .lines => "line",
            .points => "point",
        } else blk: {
            std.debug.assert(false); // mesh SPIR-V missing OutputTriangles/Lines/Points execution mode
            break :blk "triangle";
        };
        try w.print("[OutputTopology(\"{s}\")]\n", .{topo_str});
    }
    if (is_rt) {
        if (module.local_size[0] > 1 or module.local_size[1] > 1 or module.local_size[2] > 1) {
            try w.print("[numthreads({d}, {d}, {d})]\n", .{
                module.local_size[0],
                module.local_size[1],
                module.local_size[2],
            });
        }
        const stage_name: []const u8 = if (is_raygen) "raygeneration" else if (is_closesthit) "closesthit" else if (is_miss) "miss" else if (is_intersection) "intersection" else if (is_anyhit) "anyhit" else "callable";
        try w.print("[shader(\"{s}\")]\n", .{stage_name});
    }
    // Emit [earlydepthstencil] for fragment shaders with EarlyFragmentTests
    if (is_fragment and module.early_fragment_tests) {
        try w.writeAll("[earlydepthstencil]\n");
    }
    // Emit struct forward declarations for per-vertex input block types
    if (is_fragment) {
        var local_structs = std.AutoHashMap(u32, void).init(alloc);
        defer local_structs.deinit();
        var local_names = std.StringHashMap(void).init(alloc);
        defer local_names.deinit();
        for (input_var_ids.items) |ivid| {
            const is_per_vertex = hasDecoration(decorations, ivid, .per_vertex_khr) or hasDecoration(decorations, ivid, .per_vertex_nv);
            if (is_per_vertex) {
                const pointee = resolvePointeeType(module, ivid);
                if (pointee) |pt| {
                    const pt_inst = getDef(module, pt);
                    if (pt_inst) |pi| {
                        if (pi.op == .TypeArray and pi.words.len > 2) {
                            hlslEmitOneStructForwardDecl(module, names, pi.words[2], w, alloc, &local_structs, &local_names) catch {};
                        } else if (pi.op == .TypeStruct) {
                            hlslEmitOneStructForwardDecl(module, names, pt, w, alloc, &local_structs, &local_names) catch {};
                        }
                    }
                }
            }
        }
    }
    // Emit Private storage class variables as static globals
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Private) {
                // A const-initialised Private var was aliased to its promoted
                // const initializer (which is already declared) — skip the
                // redundant, uninitialised `static` declaration.
                if (hlslConstInitializedPrivateVar(module, inst) != null) continue;
                const type_name = try hlslType(module, inst.words[1], names, alloc);
                const arr_suffix = try hlslGetArraySuffix(module, inst.words[1]);
                const vname = names.get(inst.words[2]) orelse "_private";
                try w.print("static {s} {s}{s};\n", .{ type_name, vname, arr_suffix });
            }
        }
    }
    if (is_fragment) {
        if (output_vars.items.len > 1) {
            try w.writeAll("_MRT_OUT main(");
        } else if (output_vars.items.len == 1) {
            // Use the actual output variable type
            const ov = output_vars.items[0];
            const ov_inst = getDef(module, ov.id) orelse undefined;
            const ov_type = try hlslType(module, ov_inst.words[1], names, alloc);
            try w.print("{s} main(", .{ov_type});
        } else {
            try w.writeAll("float4 main(");
        }
    } else if (is_vertex) {
        try w.writeAll("VS_OUTPUT main(VS_INPUT input");
    } else {
        try w.print("{s} {s}(", .{ return_type, func_name });
    }

    // Emit parameters with semantics
    for (param_ids.items, 0..) |pid, i| {
        if (i > 0) try w.writeAll(", ");
        const p_inst = getDef(module, pid).?;
        const p_name = names.get(pid) orelse "p";

        // Check if parameter is a pointer type (out/inout param)
        // Also check if parameter was detected as out via the Variable+Store pattern
        const param_type_inst = getDef(module, p_inst.words[1]);
        var is_out_param = false;
        var inner_type_id = p_inst.words[1];
        if (param_type_inst) |pti| {
            if (pti.op == .TypePointer and pti.words.len > 3) {
                inner_type_id = pti.words[3]; // pointee type
            }
        }
        if (out_param_var_ids.contains(pid)) {
            is_out_param = true;
            inner_type_id = p_inst.words[1];
        }
        // Check if this param was detected as out via call-site analysis
        if (!is_out_param) {
            if (out_param_info.get(func_id)) |out_indices| {
                for (out_indices.items) |oidx| {
                    if (oidx == i) {
                        is_out_param = true;
                        break;
                    }
                }
            }
        }
        const p_type = try hlslType(module, inner_type_id, names, alloc);

        const builtin = getDecorationValue(decorations, pid, .built_in);
        const loc = getDecorationValue(decorations, pid, .location);

        if (builtin) |b| {
            const semantic = builtInToSemantic(b);
            if (is_out_param) try w.writeAll("out ");
            try w.print("{s} {s} : {s}", .{ p_type, p_name, semantic });
        } else if (loc) |l| {
            if (l == 0 and i == 0) {
                if (is_out_param) try w.writeAll("out ");
                try w.print("{s} {s} : SV_Position", .{ p_type, p_name });
            } else {
                if (is_out_param) try w.writeAll("out ");
                try w.print("{s} {s} : TEXCOORD{d}", .{ p_type, p_name, l });
            }
        } else {
            if (is_out_param) try w.writeAll("out ");
            try w.print("{s} {s}", .{ p_type, p_name });
        }
    }

    // A per-vertex (barycentric) ARRAY input `nointerpolation T v[N] : TEXCOORDk`
    // consumes N consecutive HLSL semantic slots (k..k+N-1), but glslpp keys the
    // TEXCOORD index off the SPIR-V Location (1 slot per per-vertex var). If two
    // varyings' slot ranges actually OVERLAP, dxc rejects ("Semantic 'TEXCOORD'
    // overlap"). The correct lowering is GetAttributeAtVertex (not an array) — a
    // real feature glslpp does not yet emit — so fail loud on a genuine overlap
    // rather than emit dxc-invalid HLSL. (Detection is exact: a single per-vertex
    // array, or well-spaced ones, do NOT overlap and stay supported.)
    if (is_fragment) {
        // A per-vertex ARRAY's HLSL slot span (loc..loc+N-1) collides with a
        // following varying only when N>1 — detect EXACTLY that, by checking each
        // per-vertex array's EXTENDED slots (loc+1..loc+N-1) against every other
        // (non-builtin) varying's base Location. This is barycentric-specific:
        // normal varyings that merely share a Location (e.g. invalid duplicate
        // locations in a test fixture) are NOT flagged here.
        var overlap = false;
        outer: for (input_var_ids.items) |a| {
            if (getDecorationValue(decorations, a, .built_in) != null) continue;
            if (!(hasDecoration(decorations, a, .per_vertex_khr) or hasDecoration(decorations, a, .per_vertex_nv))) continue;
            const a_loc = getDecorationValue(decorations, a, .location) orelse continue;
            var span: u32 = 1;
            if (resolvePointeeType(module, a)) |pt| {
                if (getDef(module, pt)) |pti| {
                    if (pti.op == .TypeArray and pti.words.len > 3) {
                        if (getDef(module, pti.words[3])) |li| {
                            if (li.op == .Constant and li.words.len > 3) span = li.words[3];
                        }
                    }
                }
            }
            if (span <= 1) continue;
            for (input_var_ids.items) |b| {
                if (b == a) continue;
                if (getDecorationValue(decorations, b, .built_in) != null) continue;
                const b_loc = getDecorationValue(decorations, b, .location) orelse continue;
                if (b_loc > a_loc and b_loc <= a_loc + span - 1) {
                    overlap = true;
                    break :outer;
                }
            }
        }
        if (overlap) return error.UnsupportedBarycentricArrayOverlap;
    }

    // Add input variables and builtin outputs as parameters for fragment entry function
    var first_input = if (is_fragment) param_ids.items.len == 0 else true;
    if (is_fragment) {
        for (input_var_ids.items) |ivid| {
            const iv_inst = getDef(module, ivid) orelse continue;
            const iv_name = names.get(ivid) orelse "input_var";
            const iv_type = try hlslType(module, iv_inst.words[1], names, alloc);
            const builtin = getDecorationValue(decorations, ivid, .built_in);
            if (builtin) |b| {
                // Skip helper_invocation — will use WaveIsHelperLane() inline
                const bi: spirv.BuiltIn = @enumFromInt(b);
                if (bi == .helper_invocation) continue;
                const semantic = builtInToSemantic(b);
                if (!first_input) try w.writeAll(", ");
                first_input = false;
                // Special type overrides for HLSL builtins
                if (bi == .sample_mask) {
                    // gl_SampleMaskIn → input uint SV_Coverage (scalar, not array)
                    try w.print("uint {s}_in : {s}", .{ iv_name, semantic });
                    // Alias the variable name to include _in suffix for clarity
                    const alias_name = try std.fmt.allocPrint(alloc, "{s}_in", .{iv_name});
                    if (try names.fetchPut(ivid, alias_name)) |old| alloc.free(old.value);
                } else if (bi == .sample_position) {
                    // gl_SamplePosition → no direct DXC semantic; use TEXCOORD8
                    try w.print("float2 {s} : TEXCOORD8", .{iv_name});
                } else if (bi == .sample_id) {
                    try w.print("uint {s} : {s}", .{ iv_name, semantic });
                } else if (bi == .bary_coord_khr) {
                    // gl_BaryCoordEXT → float3 SV_Barycentrics (perspective)
                    try w.print("float3 {s} : {s}", .{ iv_name, semantic });
                } else if (bi == .bary_coord_no_persp_khr) {
                    // gl_BaryCoordNoPerspEXT → noperspective float3 SV_Barycentrics
                    try w.print("noperspective float3 {s} : {s}", .{ iv_name, semantic });
                } else {
                    try w.print("{s} {s} : {s}", .{ iv_type, iv_name, semantic });
                }
            } else {
                const loc = getDecorationValue(decorations, ivid, .location);
                // Check for PerVertexKHR/PerVertexNV decoration (barycentric per-vertex inputs)
                const is_per_vertex = hasDecoration(decorations, ivid, .per_vertex_khr) or hasDecoration(decorations, ivid, .per_vertex_nv);
                if (is_per_vertex) {
                    // Emit as nointerpolation array: nointerpolation float2 vUV[3] : TEXCOORD0
                    // Get pointee type (should be TypeArray)
                    const pointee = resolvePointeeType(module, ivid);
                    if (pointee) |pt| {
                        const pt_inst = getDef(module, pt);
                        if (pt_inst) |pi| {
                            if (pi.op == .TypeArray and pi.words.len > 3) {
                                const elem_type = try hlslType(module, pi.words[2], names, alloc);
                                const arr_len = pi.words[3];
                                const len_inst = getDef(module, arr_len);
                                const len_val: u32 = if (len_inst) |li| blk: {
                                    if (li.op == .Constant and li.words.len > 3) break :blk li.words[3];
                                    break :blk 3; // default for per-vertex
                                } else 3;
                                if (loc) |l| {
                                    if (!first_input) try w.writeAll(", ");
                                    first_input = false;
                                    try w.print("nointerpolation {s} {s}[{d}] : TEXCOORD{d}", .{ elem_type, iv_name, len_val, l });
                                } else {
                                    if (!first_input) try w.writeAll(", ");
                                    first_input = false;
                                    try w.print("nointerpolation {s} {s}[{d}]", .{ elem_type, iv_name, len_val });
                                }
                            } else {
                                // Not an array — emit as nointerpolation scalar
                                if (loc) |l| {
                                    if (!first_input) try w.writeAll(", ");
                                    first_input = false;
                                    try w.print("nointerpolation {s} {s} : TEXCOORD{d}", .{ iv_type, iv_name, l });
                                } else {
                                    if (!first_input) try w.writeAll(", ");
                                    first_input = false;
                                    try w.print("nointerpolation {s} {s}", .{ iv_type, iv_name });
                                }
                            }
                        }
                    } else {
                        // Fallback: no pointee type info
                        if (loc) |l| {
                            if (!first_input) try w.writeAll(", ");
                            first_input = false;
                            try w.print("nointerpolation {s} {s} : TEXCOORD{d}", .{ iv_type, iv_name, l });
                        } else {
                            if (!first_input) try w.writeAll(", ");
                            first_input = false;
                            try w.print("nointerpolation {s} {s}", .{ iv_type, iv_name });
                        }
                    }
                } else if (loc) |l| {
                    if (!first_input) try w.writeAll(", ");
                    first_input = false;
                    try w.print("{s} {s} : TEXCOORD{d}", .{ iv_type, iv_name, l });
                } else {
                    if (!first_input) try w.writeAll(", ");
                    first_input = false;
                    try w.print("{s} {s}", .{ iv_type, iv_name });
                }
            }
        }
    }

    // Add builtin output variables as out params (e.g., gl_SampleMask → SV_Coverage)
    if (is_fragment) {
        for (builtin_output_ids.items) |boid| {
            const bo_name = names.get(boid) orelse "builtin_out";
            const bo_builtin = getDecorationValue(decorations, boid, .built_in);
            if (bo_builtin) |bb| {
                const bi: spirv.BuiltIn = @enumFromInt(bb);
                const semantic = builtInToSemantic(bb);
                if (!first_input) try w.writeAll(", ");
                first_input = false;
                if (bi == .sample_mask) {
                    try w.print("out uint {s} : {s}", .{ bo_name, semantic });
                } else {
                    try w.print("out {s} {s} : {s}", .{ "int", bo_name, semantic });
                }
            }
        }
    }

    // Mesh shader: emit thread builtins + `out vertices`/`out indices`
    // signature, plus optional `out primitives` parameter for per-primitive
    // outputs. (M5.2 v2.a / v2.b)
    if (is_mesh) {
        const max_verts = module.mesh_max_vertices orelse blk: {
            std.debug.assert(false); // SPIR-V mesh shader missing OutputVertices
            break :blk 64;
        };
        const max_prims = module.mesh_max_primitives orelse blk: {
            std.debug.assert(false); // SPIR-V mesh shader missing OutputPrimitivesEXT
            break :blk 64;
        };
        const prim_index_type: []const u8 = if (module.mesh_topology) |t| switch (t) {
            .triangles => "uint3",
            .lines => "uint2",
            .points => "uint",
        } else blk: {
            std.debug.assert(false); // mesh SPIR-V missing OutputTriangles/Lines/Points execution mode
            break :blk "uint3";
        };

        if (!first_input) try w.writeAll(", ");
        first_input = false;
        try w.writeAll("uint3 tid : SV_DispatchThreadID");
        try w.writeAll(", uint3 gtid : SV_GroupThreadID");
        try w.writeAll(", uint3 gid : SV_GroupID");

        // `out vertices VertexOut verts[max_vertices]` — references the
        // VertexOut struct emitted earlier in the file.
        try w.print(", out vertices VertexOut verts[{d}]", .{max_verts});
        // `out indices <topology-shape> prims[max_primitives]` — topology
        // index buffer (uint3 for triangles, uint2 for lines, uint for points).
        try w.print(", out indices {s} prims[{d}]", .{ prim_index_type, max_prims });
        // `out primitives PrimOut prims_data[max_primitives]` — only when
        // `perprimitiveEXT`-decorated outputs exist.
        if (mesh_prim_fields.items.len > 0) {
            try w.print(", out primitives PrimOut prims_data[{d}]", .{max_prims});
        }
    }

    // Compute system-value built-ins. The body references gl_GlobalInvocationID
    // / gl_LocalInvocationID / gl_WorkGroupID / gl_LocalInvocationIndex by name;
    // each used one must be an entry parameter with its HLSL SV semantic, else
    // dxc rejects with "use of undeclared identifier" (silent-wrong). gl_NumWork-
    // Groups has no direct HLSL system value (needs a constant buffer) and is
    // intentionally not handled here.
    if (is_compute) {
        for (module.instructions) |inst| {
            if (inst.op != .Variable or inst.words.len < 4) continue;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc != .Input) continue;
            const vid = inst.words[2];
            const b = getDecorationValue(decorations, vid, .built_in) orelse continue;
            const bi: spirv.BuiltIn = @enumFromInt(b);
            const spec: ?struct { ty: []const u8, sem: []const u8 } = switch (bi) {
                .global_invocation_id => .{ .ty = "uint3", .sem = "SV_DispatchThreadID" },
                .local_invocation_id => .{ .ty = "uint3", .sem = "SV_GroupThreadID" },
                .workgroup_id => .{ .ty = "uint3", .sem = "SV_GroupID" },
                .local_invocation_index => .{ .ty = "uint", .sem = "SV_GroupIndex" },
                else => null,
            };
            if (spec) |s| {
                const nm = names.get(vid) orelse continue;
                if (!first_input) try w.writeAll(", ");
                first_input = false;
                try w.print("{s} {s} : {s}", .{ s.ty, nm, s.sem });
            }
        }
    }

    const has_mrt = is_fragment and output_vars.items.len > 1;

    // For MRT: emit struct return type with SV_Target semantics
    if (has_mrt) {
        try w.writeAll(")\n{\n");
    } else if (is_fragment) {
        try w.writeAll(") : SV_Target\n{\n");
    } else {
        try w.writeAll(")\n{\n");
    }

    // Declare output variable as local in fragment entry
    if (is_fragment) {
        if (has_mrt) {
            // Declare ALL output variables as locals for MRT
            for (output_vars.items) |ov| {
                const ov_inst = getDef(module, ov.id) orelse continue;
                const ov_type = try hlslType(module, ov_inst.words[1], names, alloc);
                const ov_name = names.get(ov.id) orelse "out";
                try w.print("    {s} {s};\n", .{ ov_type, ov_name });
            }
            // Also declare builtin outputs as locals (e.g., gl_SampleMask as uint)
            for (builtin_output_ids.items) |boid| {
                const bo_name = names.get(boid) orelse "builtin_out";
                const bo_builtin = getDecorationValue(decorations, boid, .built_in);
                if (bo_builtin) |bb| {
                    const bi: spirv.BuiltIn = @enumFromInt(bb);
                    if (bi == .sample_mask) {
                        try w.print("    uint {s};\n", .{bo_name});
                    } else {
                        try w.print("    int {s};\n", .{bo_name});
                    }
                }
            }
        } else if (output_var_id != null) {
            // Single output: only declare the primary one
            const out_var_inst = getDef(module, output_var_id.?);
            if (out_var_inst) |ovi| {
                const out_type = try hlslType(module, ovi.words[1], names, alloc);
                const out_name = names.get(output_var_id.?) orelse "_fragColor";
                try w.print("    {s} {s};\n", .{ out_type, out_name });
            }
        }
    }

    // Vertex entry: declare the local VS_OUTPUT instance the body writes into.
    if (is_vertex) {
        try w.writeAll("    VS_OUTPUT output;\n");
    }

    // Emit body
    try emitBody(module, names, decorations, func_idx, w, alloc, is_fragment, is_vertex, output_var_id);

    // Return output var for fragment
    if (is_fragment and output_var_id != null) {
        if (has_mrt) {
            // Fill the MRT struct and return
            try w.writeAll("    _MRT_OUT _mrt_out;\n");
            for (output_vars.items) |ov| {
                const ov_name = names.get(ov.id) orelse "out";
                try w.print("    _mrt_out.{s} = {s};\n", .{ ov_name, ov_name });
            }
            try w.writeAll("    return _mrt_out;\n");
        } else {
            const out_name = names.get(output_var_id.?) orelse "_out";
            try w.print("    return {s};\n", .{out_name});
        }
    } else if (is_fragment) {
        // Empty fragment shader — return default value
        try w.writeAll("    return float4(0.0, 0.0, 0.0, 0.0);\n");
    } else if (is_vertex) {
        // Vertex entry: return the populated output struct.
        try w.writeAll("    return output;\n");
    }

    try w.writeAll("}\n");
}

fn hlslSafeName(name: []const u8) []const u8 {
    // Rename HLSL-reserved keywords and built-in type names
    if (std.mem.eql(u8, name, "line")) return "line_val";
    if (std.mem.eql(u8, name, "register")) return "register_val";
    if (std.mem.eql(u8, name, "dword")) return "dword_val";
    if (std.mem.eql(u8, name, "Buffer")) return "Buffer_val";
    return name;
}

fn builtInToSemantic(b: u32) []const u8 {
    const bi: spirv.BuiltIn = @enumFromInt(b);
    return switch (bi) {
        .frag_coord => "SV_Position",
        .front_facing => "SV_IsFrontFace",
        .layer => "SV_RenderTargetArrayIndex",
        .view_index => "SV_ViewID",
        .sample_id => "SV_SampleIndex",
        .sample_mask => "SV_Coverage",
        .sample_position => "SV_Position",
        .bary_coord_khr => "SV_Barycentrics",
        .bary_coord_no_persp_khr => "SV_Barycentrics1",
        else => "TEXCOORD0",
    };
}

// ---------------------------------------------------------------------------
// Body emission — linear scan with expression tracking
// ---------------------------------------------------------------------------

fn emitBody(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_idx: usize,
    w: anytype,
    alloc: std.mem.Allocator,
    is_fragment: bool,
    is_vertex: bool,
    output_var_id: ?u32,
) !void {
    // Build label → instruction index map
    var label_map = std.AutoHashMap(u32, usize).init(alloc);
    defer label_map.deinit();
    var idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .Label and inst.words.len > 1) {
            label_map.put(inst.words[1], idx) catch {};
        }
    }

    // Build BranchConditional index → merge label map
    // For each SelectionMerge, record its merge label. Then find the next BranchConditional.
    var bc_merge_map = std.AutoHashMap(usize, u32).init(alloc);
    defer bc_merge_map.deinit();
    idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .SelectionMerge and inst.words.len > 1) {
            const merge_label = inst.words[1];
            // Find the BranchConditional that follows (in the same basic block)
            var j = idx + 1;
            while (j < module.instructions.len) : (j += 1) {
                const next = module.instructions[j];
                if (next.op == .BranchConditional) {
                    bc_merge_map.put(j, merge_label) catch {};
                    break;
                }
                // Stop at any other instruction that indicates end of basic block
                if (next.op == .Branch or next.op == .ReturnValue or next.op == .Return or next.op == .Kill) break;
                if (next.op != .Label and next.op != .SelectionMerge and next.op != .LoopMerge) break;
            }
            // Also check for OpSwitch after SelectionMerge
            var k = idx + 1;
            while (k < module.instructions.len) : (k += 1) {
                const next = module.instructions[k];
                if (next.op == .Switch) {
                    bc_merge_map.put(k, merge_label) catch {};
                    break;
                }
                if (next.op == .Branch or next.op == .ReturnValue or next.op == .Return or next.op == .Kill) break;
                if (next.op != .Label and next.op != .SelectionMerge and next.op != .LoopMerge) break;
            }
        }
    }

    // Build LoopMerge index → {merge_label, continue_label} map
    var loop_merge_map = std.AutoHashMap(usize, LoopInfo).init(alloc);
    defer loop_merge_map.deinit();
    idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .LoopMerge and inst.words.len >= 3) {
            loop_merge_map.put(idx, .{ .merge = inst.words[1], .cont = inst.words[2] }) catch {};
        }
    }

    // Pre-pass: identify loop-header OpPhi (loop counters). A loop-header phi must
    // be materialized as a MUTABLE variable initialized to its preheader operand and
    // updated at the loop back-edge — otherwise the counter freezes at its init value
    // (silent-wrong infinite loop). For "pattern B" loops (condition computed in the
    // header block), the condition instructions are deferred and replayed inside the
    // loop so the comparison re-evaluates against the live counter each iteration.
    var loop_phis = std.AutoHashMap(usize, std.ArrayList(PhiInfo)).init(alloc);
    defer {
        var lpit = loop_phis.valueIterator();
        while (lpit.next()) |list| list.deinit(alloc);
        loop_phis.deinit();
    }
    var phi_hdr = std.AutoHashMap(u32, usize).init(alloc); // phi result_id -> LoopMerge idx
    defer phi_hdr.deinit();
    var deferred_hdr = std.AutoHashMap(usize, void).init(alloc); // header cond instr idx -> skip & replay
    defer deferred_hdr.deinit();
    {
        var li = func_idx + 1;
        while (li < module.instructions.len) : (li += 1) {
            const minst = module.instructions[li];
            if (minst.op == .FunctionEnd) break;
            if (minst.op != .LoopMerge or minst.words.len < 3) continue;
            // Header label = nearest preceding Label.
            var hlabel_idx: usize = li;
            while (hlabel_idx > func_idx) : (hlabel_idx -= 1) {
                if (module.instructions[hlabel_idx].op == .Label) break;
            }
            var plist = std.ArrayList(PhiInfo).initCapacity(alloc, 2) catch continue;
            var p = hlabel_idx + 1;
            while (p < li) : (p += 1) {
                const pinst = module.instructions[p];
                if (pinst.op != .Phi or pinst.words.len < 5) continue;
                // Classify (value,label) pairs: label defined BEFORE the header is the
                // preheader (init); a label defined AFTER is the back-edge (update).
                var init_id: u32 = pinst.words[3];
                var update_id: u32 = if (pinst.words.len >= 6) pinst.words[5] else pinst.words[3];
                var pp: usize = 3;
                while (pp + 1 < pinst.words.len) : (pp += 2) {
                    const val_id = pinst.words[pp];
                    const lbl_id = pinst.words[pp + 1];
                    if (label_map.get(lbl_id)) |lx| {
                        if (lx < hlabel_idx) init_id = val_id else update_id = val_id;
                    }
                }
                plist.append(alloc, .{ .result_id = pinst.words[2], .type_id = pinst.words[1], .init_id = init_id, .update_id = update_id }) catch {};
                phi_hdr.put(pinst.words[2], li) catch {};
            }
            loop_phis.put(li, plist) catch plist.deinit(alloc);
            // Pattern B: BranchConditional directly after LoopMerge -> the condition
            // lives in the header block; defer its non-phi instrs for in-loop replay.
            if (li + 1 < module.instructions.len and module.instructions[li + 1].op == .BranchConditional) {
                var d = hlabel_idx + 1;
                while (d < li) : (d += 1) {
                    if (module.instructions[d].op != .Phi) deferred_hdr.put(d, {}) catch {};
                }
            }
        }
    }

    // Structured emission
    idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        // Header condition instrs (pattern B) are replayed inside the loop, not here.
        if (deferred_hdr.contains(idx)) continue;
        if (inst.op == .FunctionParameter or inst.op == .Label or
            inst.op == .SelectionMerge or inst.op == .Branch) continue;

        // Loop-header OpPhi: emit the loop counter as a mutable variable.
        if (inst.op == .Phi) {
            if (phi_hdr.get(inst.words[2])) |lmi| {
                if (loop_phis.get(lmi)) |plist| {
                    for (plist.items) |pi| {
                        if (pi.result_id != inst.words[2]) continue;
                        const tyname = phiTypeNameHLSL(module, pi.type_id);
                        if (names.get(pi.result_id) == null) {
                            const nm = std.fmt.allocPrint(alloc, "v{d}", .{pi.result_id}) catch "vphi";
                            if (names.fetchPut(pi.result_id, nm) catch null) |old| alloc.free(old.value);
                        }
                        const vname = names.get(pi.result_id) orelse "vphi";
                        const init_name = names.get(pi.init_id) orelse "0";
                        try w.print("    {s} {s} = {s};\n", .{ tyname, vname, init_name });
                    }
                }
                continue;
            }
            // Non-loop phi: existing select-the-first-operand behavior.
            try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, is_vertex, output_var_id);
            continue;
        }

        // Handle LoopMerge: emit while(true) { condition; if(!cond) break; body; }
        if (inst.op == .LoopMerge and inst.words.len >= 3) {
            const merge_lbl = inst.words[1];
            const cont_lbl = inst.words[2];
            idx = try emitWhileLoopHLSL(module, names, decorations, idx, merge_lbl, cont_lbl, &label_map, &bc_merge_map, &loop_merge_map, &loop_phis, &phi_hdr, &deferred_hdr, w, alloc, is_fragment, is_vertex, output_var_id);
            continue;
        }

        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cond_id = inst.words[1];
            const true_label = inst.words[2];
            const false_label = if (inst.words.len > 3) inst.words[3] else null;
            const merge_label = bc_merge_map.get(idx);

            const cond_name = names.get(cond_id) orelse "c";

            if (merge_label) |ml| {
                const has_else = false_label != null and false_label.? != ml;
                try w.print("    if ({s}) {{\n", .{cond_name});
                // Emit true branch
                idx = try emitBlock(module, names, decorations, true_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "    ");
                if (has_else) {
                    try w.writeAll("    } else {\n");
                    idx = try emitBlock(module, names, decorations, false_label.?, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                // Advance to merge label
                if (label_map.get(ml)) |merge_idx| {
                    idx = merge_idx; // loop will increment
                }
            } else {
                // Unstructured control flow (OpBranchConditional without
                // OpSelectionMerge). The convergence-guessing reconstruction is
                // silent-wrong; fail loud. glslpp's own frontend always emits
                // merge info. Mirrors the GLSL backend (#88). Backlog #4 (G2).
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        if (inst.op == .Switch) {
            // OpSwitch: Selector Default [Case Target ...]
            if (inst.words.len < 3) continue;
            const selector_id = inst.words[1];
            const default_label = inst.words[2];
            const merge_label = bc_merge_map.get(idx);
            const selector_name = names.get(selector_id) orelse "s";

            if (merge_label) |ml| {
                try w.print("    switch ({s}) {{\n", .{selector_name});
                // Emit default case first if it's not the merge label
                if (default_label != ml) {
                    try w.writeAll("    default:\n");
                    _ = try emitBlock(module, names, decorations, default_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "    ");
                }
                // Emit case labels (word 3+: pairs of literal, target)
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const case_val = inst.words[wi];
                    const target_label = inst.words[wi + 1];
                    if (target_label == ml) continue; // skip branches to merge
                    try w.print("    case {d}:\n", .{case_val});
                    _ = try emitBlock(module, names, decorations, target_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                // Advance to merge label
                if (label_map.get(ml)) |merge_idx| {
                    idx = merge_idx;
                }
            } else {
                // Unstructured control flow (OpSwitch without OpSelectionMerge).
                // The convergence-guessing reconstruction is silent-wrong (drops
                // the default case / elides the switch); fail loud. Mirrors the
                // GLSL backend (#88). Backlog #4 (G2) = structurize.
                return error.UnstructuredControlFlow;
            }
            continue;
        }

        try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, is_vertex, output_var_id);
    }
}

/// A do-while (bottom-test) loop's CONTINUE block ends in a back-edge
/// `OpBranchConditional` whose two targets are exactly {header, merge}. A normal
/// top-test loop's continue block ends in an unconditional `OpBranch header`.
/// Returns the index of that back-edge BranchConditional, else null. Must be
/// consulted BEFORE scanning the body for a condition (#244): otherwise a
/// body-local `if` is mis-detected as the loop condition.
fn detectDoWhileBackEdge(
    module: *const ParsedModule,
    cont_lbl: u32,
    header_lbl: u32,
    merge_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) ?usize {
    const ci = label_map.get(cont_lbl) orelse return null;
    var s = ci + 1;
    while (s < module.instructions.len) : (s += 1) {
        const t = module.instructions[s];
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

/// Emit instructions from a block starting at `label` until we reach a Branch to `merge_label`.
/// Handles nested if/else by recursion.
/// Returns the index of the last instruction processed.
fn emitWhileLoopHLSL(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    loop_idx: usize,
    merge_lbl: u32,
    cont_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    bc_merge_map: *const std.AutoHashMap(usize, u32),
    loop_merge_map: *const std.AutoHashMap(usize, LoopInfo),
    loop_phis: *const std.AutoHashMap(usize, std.ArrayList(PhiInfo)),
    phi_hdr: *const std.AutoHashMap(u32, usize),
    deferred_hdr: *const std.AutoHashMap(usize, void),
    w: anytype,
    alloc: std.mem.Allocator,
    is_fragment: bool,
    is_vertex: bool,
    output_var_id: ?u32,
) !usize {
    // Three patterns after LoopMerge:
    // Pattern A: LoopMerge; Branch cond_label; ...; BranchConditional cond, body, merge
    // Pattern B: LoopMerge; BranchConditional cond, body, merge (merged condition)
    // Pattern C (do-while / bottom-test): LoopMerge; Branch body; ...; the continue
    //   block ends in BranchConditional cond, header, merge (condition at back-edge).

    var cond_name: []const u8 = "true";
    var body_lbl: u32 = 0;
    var bc_idx: usize = loop_idx + 1;
    var cond_start: ?usize = null; // start of condition instructions (for pattern A)
    var cond_end: usize = loop_idx + 1; // end of condition instructions
    var is_do_while = false; // pattern C: condition tested at the back-edge
    var dw_loop_when_true = true; // back-edge BranchConditional loops when cond is true

    if (loop_idx + 1 >= module.instructions.len) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    // Header label = nearest Label before the LoopMerge (needed for do-while
    // back-edge detection).
    var hlbl_idx: usize = loop_idx;
    while (hlbl_idx > 0) : (hlbl_idx -= 1) {
        if (module.instructions[hlbl_idx].op == .Label) break;
    }
    const header_lbl: u32 = if (module.instructions[hlbl_idx].words.len > 1) module.instructions[hlbl_idx].words[1] else 0;

    const next_inst = module.instructions[loop_idx + 1];
    if (next_inst.op == .Branch and next_inst.words.len >= 2) {
        // FIRST: is this a do-while (bottom-test) loop? Inspect the CONTINUE block's
        // terminator BEFORE scanning the body. Otherwise the body's own `if`
        // BranchConditional (`if(x) continue;`) is mis-grabbed as the loop condition,
        // which crashes / silently miscompiles (inverted polarity, dup temps) — #244.
        if (detectDoWhileBackEdge(module, cont_lbl, header_lbl, merge_lbl, label_map)) |dw_bc| {
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
            // Find BranchConditional in condition block
            bc_idx = cond_idx + 1;
            while (bc_idx < module.instructions.len) : (bc_idx += 1) {
                const scan = module.instructions[bc_idx];
                if (scan.op == .BranchConditional) break;
                if (scan.op == .Branch or scan.op == .FunctionEnd or scan.op == .Label) {
                    bc_idx = module.instructions.len;
                    break;
                }
            }
            if (bc_idx >= module.instructions.len) {
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

    const bc = module.instructions[bc_idx];
    if (bc.words.len < 4) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }
    cond_name = names.get(bc.words[1]) orelse "true";
    body_lbl = bc.words[2];
    const false_lbl: ?u32 = if (bc.words.len > 3) bc.words[3] else null;

    if (is_do_while) {
        // The body is the LoopMerge's OpBranch target, NOT the back-edge BranchCond
        // target (which is the header). Determine whether the back-edge loops on
        // true (→ `if (!cond) break;`) or on false (→ `if (cond) break;`).
        body_lbl = next_inst.words[1];
        dw_loop_when_true = (bc.words[2] == header_lbl);

        // Only STRAIGHT-LINE do-while bodies are supported. The body is emitted with
        // the top-test machinery, which treats a branch to cont_lbl as a `continue`;
        // in a do-while cont_lbl is the CONDITION block, so conditional control flow
        // in the body (break/continue/nested loop) would be miscompiled. Fail loud.
        const bidx = label_map.get(body_lbl) orelse module.instructions.len;
        var sidx = bidx + 1;
        while (sidx < module.instructions.len) : (sidx += 1) {
            const t = module.instructions[sidx];
            if (t.op == .Label and t.words.len > 1 and t.words[1] == cont_lbl) break;
            if (t.op == .FunctionEnd) break;
            if (t.op == .SelectionMerge or t.op == .LoopMerge or t.op == .BranchConditional or t.op == .Switch) return error.UnstructuredControlFlow;
            if (t.op == .Branch and t.words.len > 1 and t.words[1] != cont_lbl) return error.UnstructuredControlFlow;
        }
    }

    // Check if this is a do-once loop: both branches of BranchConditional go to merge
    // (no actual looping, just a selection inside a loop wrapper)
    // Helper: check if a label's block ends with Branch to target
    const blockEndsAt = struct {
        fn check(mod: *const ParsedModule, lmap: *const std.AutoHashMap(u32, usize), label_id: u32, target: u32) bool {
            if (label_id == target) return true;
            const li = lmap.get(label_id) orelse return false;
            // Scan from label+1 to find the Branch
            var si: usize = li + 1;
            while (si < mod.instructions.len) : (si += 1) {
                const inst = mod.instructions[si];
                if (inst.op == .Label or inst.op == .FunctionEnd) return false;
                if (inst.op == .Branch and inst.words.len > 1) return inst.words[1] == target;
                if (inst.op == .BranchConditional) {
                    // Check if both targets go to merge
                    const t = if (inst.words.len > 2) inst.words[2] else 0;
                    const f = if (inst.words.len > 3) inst.words[3] else t;
                    return t == target and f == target;
                }
            }
            return false;
        }
    }.check;

    const true_goes_to_merge = blockEndsAt(module, label_map, body_lbl, merge_lbl);
    const false_goes_to_merge = false_lbl != null and blockEndsAt(module, label_map, false_lbl.?, merge_lbl);

    if (true_goes_to_merge and false_goes_to_merge) {
        // Both branches exit to merge — this is not a real loop, just a selection
        // Emit as: if (cond) { true_block } else { false_block }
        try w.writeAll("    ");
        // Emit condition block instructions (for pattern A)
        if (cond_start) |cs| {
            if (cs < cond_end) {
                var ci: usize = cs;
                while (ci < cond_end) : (ci += 1) {
                    const cinst = module.instructions[ci];
                    if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                    try emitInstruction(module, names, decorations, cinst, w, alloc, is_fragment, is_vertex, output_var_id);
                }
            }
        }
        try w.print("if ({s})\n    {{\n", .{cond_name});
        // Emit true block (body_lbl → merge)
        if (body_lbl != merge_lbl) {
            const tli = label_map.get(body_lbl) orelse module.instructions.len;
            if (tli < module.instructions.len) {
                var ti: usize = tli + 1;
                while (ti < module.instructions.len) : (ti += 1) {
                    const tinst = module.instructions[ti];
                    if (tinst.op == .FunctionEnd) break;
                    if (tinst.op == .Label) break;
                    if (tinst.op == .Branch) continue;
                    try emitInstruction(module, names, decorations, tinst, w, alloc, is_fragment, is_vertex, output_var_id);
                }
            }
        }
        try w.writeAll("    }");
        if (false_lbl != null and false_lbl.? != merge_lbl) {
            try w.writeAll(" else {\n");
            const fli = label_map.get(false_lbl.?) orelse module.instructions.len;
            if (fli < module.instructions.len) {
                var fi: usize = fli + 1;
                while (fi < module.instructions.len) : (fi += 1) {
                    const finst = module.instructions[fi];
                    if (finst.op == .FunctionEnd) break;
                    if (finst.op == .Label) break;
                    if (finst.op == .Branch) continue;
                    try emitInstruction(module, names, decorations, finst, w, alloc, is_fragment, is_vertex, output_var_id);
                }
            }
            try w.writeAll("    }");
        }
        try w.writeAll("\n");
        // Skip to merge label
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    // #237: For a loop with an SSA phi counter, the back-edge counter update must
    // run on EVERY iteration including `continue` paths. A C `continue` in a
    // `while(true)` skips the bottom-of-loop update, so instead we run the update
    // at the TOP of the loop guarded by a first-iteration flag: a plain `continue`
    // then re-enters the top and advances the counter (matching a real `for`).
    var fbuf: [40]u8 = undefined;
    const first_flag = std.fmt.bufPrint(&fbuf, "_loopfirst_{d}", .{loop_idx}) catch "_loopfirst";
    // do-while loops test the condition at the bottom and carry their update in the
    // body, so the #237 top-of-loop first-flag transform does not apply.
    const has_phis = !is_do_while and (if (loop_phis.get(loop_idx)) |pl| pl.items.len > 0 else false);
    if (has_phis) try w.print("    bool {s} = true;\n", .{first_flag});

    // Emit: while (true) {
    try w.writeAll("    while (true)\n    {\n");

    if (has_phis) {
        // Run the counter update at the top, except on the first iteration.
        try w.print("        if (!{s})\n        {{\n", .{first_flag});
        const cont_idx0 = label_map.get(cont_lbl) orelse module.instructions.len;
        if (cont_idx0 < module.instructions.len) {
            var ci0: usize = cont_idx0 + 1;
            while (ci0 < module.instructions.len) : (ci0 += 1) {
                const cinst = module.instructions[ci0];
                if (cinst.op == .FunctionEnd or cinst.op == .Label or cinst.op == .Branch) break;
                if (cinst.op == .LoopMerge or cinst.op == .SelectionMerge) continue;
                try emitInstruction(module, names, decorations, cinst, w, alloc, is_fragment, is_vertex, output_var_id);
            }
        }
        if (loop_phis.get(loop_idx)) |plist| {
            for (plist.items) |pi| {
                const rname = names.get(pi.result_id) orelse continue;
                const vname = names.get(pi.update_id) orelse continue;
                if (std.mem.eql(u8, rname, vname)) continue;
                try w.print("        {s} = {s};\n", .{ rname, vname });
            }
        }
        try w.writeAll("        }\n");
        try w.print("        {s} = false;\n", .{first_flag});
    }

    // Emit condition block instructions (for pattern A)
    if (cond_start) |cs| {
        if (cs < cond_end) {
            var ci: usize = cs;
            while (ci < cond_end) : (ci += 1) {
                const cinst = module.instructions[ci];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                try emitInstruction(module, names, decorations, cinst, w, alloc, is_fragment, is_vertex, output_var_id);
            }
        }
    } else {
        // Pattern B: the condition is computed in the HEADER block (deferred by the
        // caller). Replay the header's non-phi instructions HERE so the comparison
        // re-evaluates against the live loop counter each iteration; otherwise it is
        // a loop-invariant test of the counter's init value (frozen → infinite loop).
        var hlabel: usize = loop_idx;
        while (hlabel > 0) : (hlabel -= 1) {
            if (module.instructions[hlabel].op == .Label) break;
        }
        var hp = hlabel + 1;
        while (hp < loop_idx) : (hp += 1) {
            const hinst = module.instructions[hp];
            if (hinst.op == .Phi or hinst.op == .Label or hinst.op == .SelectionMerge or hinst.op == .LoopMerge or hinst.op == .Branch or hinst.op == .BranchConditional) continue;
            try emitInstruction(module, names, decorations, hinst, w, alloc, is_fragment, is_vertex, output_var_id);
        }
        // The condition value was just (re)named by the replay; refresh it.
        cond_name = names.get(bc.words[1]) orelse cond_name;
    }

    // Emit: if (!(condition)) break;  — top-test only. A do-while tests at the bottom.
    if (!is_do_while) try w.print("        if (!({s})) break;\n", .{cond_name});

    // Emit body block
    const body_idx = label_map.get(body_lbl) orelse module.instructions.len;
    if (body_idx < module.instructions.len) {
        var bi: usize = body_idx + 1;
        while (bi < module.instructions.len) : (bi += 1) {
            const binst = module.instructions[bi];
            if (binst.op == .FunctionEnd) break;
            // A NESTED loop's header condition (pattern B) is deferred and replayed
            // inside that nested loop — skip it here so it isn't emitted prematurely
            // against the frozen counter.
            if (deferred_hdr.contains(bi)) continue;
            // A NESTED loop-header phi: emit it as a mutable variable BEFORE the
            // nested `while`, exactly as the top-level path does.
            if (binst.op == .Phi) {
                if (phi_hdr.get(binst.words[2])) |lmi| {
                    if (loop_phis.get(lmi)) |plist| {
                        for (plist.items) |pi| {
                            if (pi.result_id != binst.words[2]) continue;
                            const tyname = phiTypeNameHLSL(module, pi.type_id);
                            if (names.get(pi.result_id) == null) {
                                const nm = std.fmt.allocPrint(alloc, "v{d}", .{pi.result_id}) catch "vphi";
                                if (names.fetchPut(pi.result_id, nm) catch null) |old| alloc.free(old.value);
                            }
                            const vname = names.get(pi.result_id) orelse "vphi";
                            const init_name = names.get(pi.init_id) orelse "0";
                            try w.print("        {s} {s} = {s};\n", .{ tyname, vname, init_name });
                        }
                    }
                    continue;
                }
            }
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
                    bi = try emitWhileLoopHLSL(module, names, decorations, bi, nmerge, ncont, label_map, bc_merge_map, loop_merge_map, loop_phis, phi_hdr, deferred_hdr, w, alloc, is_fragment, is_vertex, output_var_id);
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
                const nml = bc_merge_map.get(bi);
                // Check if true/false labels are trivial continue/break
                const tl_is_trivial_continue = blk: { if (ntl == cont_lbl) break :blk true; const tli = label_map.get(ntl) orelse break :blk false; if (tli + 2 < module.instructions.len and module.instructions[tli].op == .Label and module.instructions[tli + 1].op == .Branch and module.instructions[tli + 1].words.len > 1 and module.instructions[tli + 1].words[1] == cont_lbl) break :blk true; break :blk false; };
                const fl_is_trivial_continue = blk: { if (nfl == null) break :blk false; if (nfl.? == cont_lbl) break :blk true; const fli = label_map.get(nfl.?) orelse break :blk false; if (fli + 2 < module.instructions.len and module.instructions[fli].op == .Label and module.instructions[fli + 1].op == .Branch and module.instructions[fli + 1].words.len > 1 and module.instructions[fli + 1].words[1] == cont_lbl) break :blk true; break :blk false; };
                const tl_is_trivial_break = blk: { if (ntl == merge_lbl) break :blk true; const tli2 = label_map.get(ntl) orelse break :blk false; if (tli2 + 2 < module.instructions.len and module.instructions[tli2].op == .Label and module.instructions[tli2 + 1].op == .Branch and module.instructions[tli2 + 1].words.len > 1 and module.instructions[tli2 + 1].words[1] == merge_lbl) break :blk true; break :blk false; };
                const fl_is_trivial_break = blk: { if (nfl == null) break :blk false; if (nfl.? == merge_lbl) break :blk true; const fli2 = label_map.get(nfl.?) orelse break :blk false; if (fli2 + 2 < module.instructions.len and module.instructions[fli2].op == .Label and module.instructions[fli2 + 1].op == .Branch and module.instructions[fli2 + 1].words.len > 1 and module.instructions[fli2 + 1].words[1] == merge_lbl) break :blk true; break :blk false; };
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    if (tl_is_trivial_continue and (fl_is_trivial_break or !nhe)) {
                        try w.print("        if ({s}) continue;\n", .{ncn});
                    } else if (tl_is_trivial_break and fl_is_trivial_continue) {
                        try w.print("        if ({s}) break;\n", .{ncn});
                        try w.writeAll("        continue;\n");
                    } else if (tl_is_trivial_continue and nhe) {
                        try w.print("        if ({s}) continue;\n", .{ncn});
                        bi = try emitBlock(module, names, decorations, nfl.?, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                    } else if (tl_is_trivial_break) {
                        try w.print("        if ({s}) break;\n", .{ncn});
                        if (nhe) {
                            bi = try emitBlock(module, names, decorations, nfl.?, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                        }
                    } else if (fl_is_trivial_continue) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(module, names, decorations, ntl, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                        try w.writeAll("        } continue;\n");
                    } else if (fl_is_trivial_break and !nhe) {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(module, names, decorations, ntl, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                        try w.writeAll("        }\n");
                    } else {
                        try w.print("        if ({s})\n        {{\n", .{ncn});
                        bi = try emitBlock(module, names, decorations, ntl, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                        if (nhe) {
                            try w.writeAll("        } else {\n");
                            bi = try emitBlock(module, names, decorations, nfl.?, nmv, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, "        ");
                        }
                        try w.writeAll("        }\n");
                    }
                    if (label_map.get(nmv)) |nmi| {
                        bi = nmi;
                    }
                }
                continue;
            }
            try emitInstruction(module, names, decorations, binst, w, alloc, is_fragment, is_vertex, output_var_id);
        }
    }
    // Emit continue block (e.g., i++ in for-loops, or the do-while back-edge
    // condition). For phi-counter loops the update was hoisted to the top (#237),
    // so skip it here.
    if (!has_phis) {
        const cont_idx = label_map.get(cont_lbl) orelse module.instructions.len;
        if (cont_idx < module.instructions.len) {
            var ci2: usize = cont_idx + 1;
            while (ci2 < module.instructions.len) : (ci2 += 1) {
                const cinst = module.instructions[ci2];
                if (cinst.op == .FunctionEnd) break;
                if (cinst.op == .Label) break;
                if (cinst.op == .Branch) break;
                if (cinst.op == .BranchConditional) break; // do-while back-edge — handled below
                if (cinst.op == .LoopMerge or cinst.op == .SelectionMerge) continue;
                try emitInstruction(module, names, decorations, cinst, w, alloc, is_fragment, is_vertex, output_var_id);
            }
        }
    }

    // do-while (pattern C): the condition was just emitted (continue block); test it
    // at the BOTTOM. Loop-on-true → `if (!cond) break;`, loop-on-false → `if (cond) break;`.
    if (is_do_while) {
        const dwc = names.get(bc.words[1]) orelse "true";
        if (dw_loop_when_true) {
            try w.print("        if (!({s})) break;\n", .{dwc});
        } else {
            try w.print("        if ({s}) break;\n", .{dwc});
        }
    }

    try w.writeAll("    }\n");
    if (label_map.get(merge_lbl)) |mi| return mi;
    return loop_idx + 1;
}

fn emitBlock(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    label: u32,
    merge_label: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    bc_merge_map: *const std.AutoHashMap(usize, u32),
    w: anytype,
    alloc: std.mem.Allocator,
    is_fragment: bool,
    is_vertex: bool,
    output_var_id: ?u32,
    indent: []const u8,
) !usize {
    const start_idx = label_map.get(label) orelse return error.InvalidSpirv;
    var i: usize = start_idx + 1; // skip the Label
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];
        if (inst.op == .FunctionEnd) break;

        // Branch to merge = end of this block
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == merge_label) break;

        // Skip structural instructions
        if (inst.op == .Label or inst.op == .SelectionMerge or inst.op == .LoopMerge) continue;
        if (inst.op == .Branch) break; // branch to somewhere else (e.g., loop back-edge)

        // Handle nested BranchConditional
        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cond_id = inst.words[1];
            const true_lbl = inst.words[2];
            const false_lbl = if (inst.words.len > 3) inst.words[3] else null;
            const nested_merge = bc_merge_map.get(i);
            const cond_name = names.get(cond_id) orelse "c";

            if (nested_merge) |nm| {
                const has_else = false_lbl != null and false_lbl.? != nm;
                try w.print("{s}    if ({s}) {{\n", .{ indent, cond_name });
                i = try emitBlock(module, names, decorations, true_lbl, nm, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, indent);
                if (has_else) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    i = try emitBlock(module, names, decorations, false_lbl.?, nm, label_map, bc_merge_map, w, alloc, is_fragment, is_vertex, output_var_id, indent);
                }
                try w.print("{s}    }}\n", .{indent});
                // Skip to nested merge label
                if (label_map.get(nm)) |nm_idx| {
                    i = nm_idx; // loop will increment
                }
            } else {
                try w.print("{s}    if ({s}) {{ /* no merge */ }}\n", .{ indent, cond_name });
            }
            continue;
        }

        // Regular instruction — emit it
        // Note: we can't easily change the indentation of emitInstruction
        // since it always emits "    " prefix. For now, accept same indentation.
        try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, is_vertex, output_var_id);
    }
    return i;
}

fn emitInstruction(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    inst: Instruction,
    w: anytype,
    alloc: std.mem.Allocator,
    is_fragment: bool,
    is_vertex: bool,
    output_var_id: ?u32,
) !void {
    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            // Vertex Input/Output globals: live in VS_INPUT/VS_OUTPUT structs
            // (the names map was rewritten to `input.<f>` / `output.<f>`); do
            // not emit any local declaration.
            if (is_vertex and (sc == .Input or sc == .Output)) return;
            // Output variables in fragment entry: declare as local (will be returned)
            if (sc == .Output and is_fragment) {
                const result_id = inst.words[2];
                const type_name = try hlslType(module, inst.words[1], names, alloc);
                const arr_suffix = try hlslGetArraySuffix(module, inst.words[1]);
                try w.print("    {s} {s}{s};\n", .{ type_name, names.get(result_id) orelse "var", arr_suffix });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .StorageBuffer or sc == .UniformConstant) return;
            const result_id = inst.words[2];
            const type_name = try hlslType(module, inst.words[1], names, alloc);
            const arr_suffix = try hlslGetArraySuffix(module, inst.words[1]);
            // Check for variable initializer (5th word)
            if (inst.words.len >= 5) {
                const init_id = inst.words[4];
                const init_name = names.get(init_id);
                if (init_name) |in| {
                    try w.print("    {s} {s}{s} = {s};\n", .{ type_name, names.get(result_id) orelse "var", arr_suffix, in });
                    return;
                }
                // Try to resolve constant composite initializer inline
                const init_inst = getDef(module, init_id);
                if (init_inst) |ii| {
                    if (ii.op == .ConstantComposite and ii.words.len > 3) {
                        // Build initializer expression: {comp0, comp1, ...}
                        var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return;
                        defer buf.deinit(alloc);
                        buf.appendSlice(alloc, "{") catch return;
                        for (ii.words[3..], 0..) |comp_id, ci| {
                            if (ci > 0) buf.appendSlice(alloc, ", ") catch return;
                            const comp_name = names.get(comp_id) orelse "0";
                            buf.appendSlice(alloc, comp_name) catch return;
                        }
                        buf.appendSlice(alloc, "}") catch return;
                        try w.print("    {s} {s}{s} = {s};\n", .{ type_name, names.get(result_id) orelse "var", arr_suffix, buf.items });
                        return;
                    }
                }
            }
            try w.print("    {s} {s}{s};\n", .{ type_name, names.get(result_id) orelse "var", arr_suffix });
        },

        .Load => {
            const result_type = try hlslType(module, inst.words[1], names, alloc);
            const result_name = names.get(inst.words[2]) orelse "v";
            const ptr_id = inst.words[3];
            const ptr_name = names.get(ptr_id) orelse "var";

            // Check if loading from a texture/sampler — in HLSL these are used directly
            const ptr_inst = getDef(module, ptr_id);
            var is_texture_or_sampler = false;
            var is_output_load = false;
            if (ptr_inst) |pi| {
                if (pi.op == .Variable and pi.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(pi.words[3]);
                    if (sc == .UniformConstant) {
                        // Check pointee type
                        const ptr_type = getDef(module, pi.words[1]);
                        if (ptr_type) |pt| {
                            if (pt.op == .TypePointer and pt.words.len > 3) {
                                const pointee = getDef(module, pt.words[3]);
                                if (pointee) |pp| {
                                    if (pp.op == .TypeSampler or pp.op == .TypeSampledImage or pp.op == .TypeImage) {
                                        is_texture_or_sampler = true;
                                    }
                                }
                            }
                        }
                    }
                    // Skip loads from Output variable in fragment entry — they pass by reference
                    if (sc == .Output and is_fragment) {
                        is_output_load = true;
                    }
                    // Skip loads from Input variable in fragment entry — they're parameters
                    if (sc == .Input and is_fragment) {
                        is_output_load = true;
                    }
                    // Vertex stage: loads from Input/Output route through the rewritten
                    // name (e.g. `input.in_pos` / `output.gl_Position`), so alias the
                    // load result to that name and skip emitting a separate read.
                    if ((sc == .Input or sc == .Output) and is_vertex) {
                        is_output_load = true;
                    }
                }
            }

            // Check if loading gl_HelperInvocation — replace with WaveIsHelperLane()
            var is_helper_invocation = false;
            if (ptr_inst) |pi| {
                if (pi.op == .Variable) {
                    const helper_builtin = getDecorationValue(decorations, ptr_id, .built_in);
                    if (helper_builtin) |hb| {
                        const bi: spirv.BuiltIn = @enumFromInt(hb);
                        if (bi == .helper_invocation) {
                            is_helper_invocation = true;
                            const expr = try std.fmt.allocPrint(alloc, "IsHelperLane()", .{});
                            if (try names.fetchPut(inst.words[2], expr)) |old| alloc.free(old.value);
                        }
                    }
                }
            }
            if (is_helper_invocation) {
                // Already mapped result to WaveIsHelperLane() expression
            } else if (is_output_load) {
                // Alias the load result to the output variable name (for passing to functions)
                const alias = try alloc.dupe(u8, ptr_name);
                if (try names.fetchPut(inst.words[2], alias)) |old| alloc.free(old.value);
            } else if (is_texture_or_sampler) {
                // Check if it's a sampled image (combined texture+sampler)
                const var_type_id = ptr_inst.?.words[1];
                const ptr_type_inst2 = getDef(module, var_type_id);
                var is_sampled_image = false;
                if (ptr_type_inst2) |pt2| {
                    if (pt2.op == .TypePointer and pt2.words.len > 3) {
                        const pointee = getDef(module, pt2.words[3]);
                        if (pointee) |pp| is_sampled_image = (pp.op == .TypeSampledImage);
                    }
                }
                if (is_sampled_image) {
                    // Map to texture,sampler pair
                    const pair = try std.fmt.allocPrint(alloc, "{s},{s}_sampler", .{ ptr_name, ptr_name });
                    if (try names.fetchPut(inst.words[2], pair)) |old| alloc.free(old.value);
                } else {
                    // Plain texture or sampler — pass through name
                    const alias = try alloc.dupe(u8, ptr_name);
                    if (try names.fetchPut(inst.words[2], alias)) |old| alloc.free(old.value);
                }
            } else {
                try w.print("    {s} {s} = ", .{ result_type, result_name });
                try writeResolvePointer(module, names, ptr_id, w);
                try w.writeAll(";\n");
            }
        },

        .Store => {
            if (inst.words.len < 3) return;
            const obj_name = names.get(inst.words[2]) orelse "0";
            try w.writeAll("    ");
            try writeResolvePointer(module, names, inst.words[1], w);
            try w.print(" = {s};\n", .{obj_name});
        },

        .CopyObject, .CopyLogical => {
            // OpCopyObject/OpCopyLogical: just alias the source ID to the result ID
            if (inst.words.len < 4) return;
            const result_id = inst.words[2];
            const source_id = inst.words[3];
            const source_name = names.get(source_id) orelse {
                const alias = try std.fmt.allocPrint(alloc, "v{d}", .{source_id});
                if (try names.fetchPut(result_id, alias)) |old| alloc.free(old.value);
                return;
            };
            const alias = try alloc.dupe(u8, source_name);
            if (try names.fetchPut(result_id, alias)) |old| alloc.free(old.value);
        },

        .CopyMemory => {
            // OpCopyMemory: target = source
            if (inst.words.len < 3) return;
            try w.writeAll("    ");
            try writeResolvePointer(module, names, inst.words[1], w);
            try w.writeAll(" = ");
            // Check if source is a zero constant and target is a struct
            const src_name = names.get(inst.words[2]) orelse "0";
            if (std.mem.eql(u8, src_name, "0")) {
                // Check if target type is a struct
                const target_type = resolvePointeeType(module, inst.words[1]);
                if (target_type) |tt| {
                    const tt_inst = getDef(module, tt);
                    if (tt_inst != null and tt_inst.?.op == .TypeStruct) {
                        try w.writeAll("{}"); // struct zero-init
                        try w.writeAll(";\n");
                        return;
                    }
                }
            }
            try writeResolvePointer(module, names, inst.words[2], w);
            try w.writeAll(";\n");
        },

        .Phi => {
            // OpPhi: SSA phi node - just use the first available predecessor value
            if (inst.words.len < 4) return;
            const result_id = inst.words[2];
            // words[3..] are pairs of (value_id, label_id)
            // Take the first value as the phi result
            const first_value = inst.words[3];
            const source_name = names.get(first_value) orelse {
                const alias = try std.fmt.allocPrint(alloc, "v{d}", .{first_value});
                if (try names.fetchPut(result_id, alias)) |old| alloc.free(old.value);
                return;
            };
            const alias = try alloc.dupe(u8, source_name);
            if (try names.fetchPut(result_id, alias)) |old| alloc.free(old.value);
        },

        .AccessChain => {
            // Update the name to be the access expression
            const result_id = inst.words[2];
            const base_id = inst.words[3];
            // Check if accessing [0] on a builtin array (gl_SampleMask, gl_SampleMaskIn)
            // In HLSL these are scalar (SV_Coverage), not arrays
            var skip_chain = false;
            if (inst.words.len == 5) {
                // Single index — check if it's constant 0 and base is a sample_mask builtin
                const idx_id = inst.words[4];
                const idx_inst = getDef(module, idx_id);
                if (idx_inst) |ii| {
                    if (ii.op == .Constant and ii.words.len > 3 and ii.words[3] == 0) {
                        const base_builtin = getDecorationValue(decorations, base_id, .built_in);
                        if (base_builtin) |bb| {
                            const bi: spirv.BuiltIn = @enumFromInt(bb);
                            if (bi == .sample_mask) {
                                // Strip [0] subscript — just use the variable name
                                const base_name = names.get(base_id) orelse "base";
                                const alias = try alloc.dupe(u8, base_name);
                                if (try names.fetchPut(result_id, alias)) |old| alloc.free(old.value);
                                skip_chain = true;
                            }
                        }
                    }
                }
            }
            if (!skip_chain) {
                const expr = try buildAccessExpr(module, names, base_id, inst.words[4..], alloc);
                // Replace the name
                if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
            }
        },

        // Arithmetic
        .FAdd, .IAdd => try emitBinOp(module, names, inst, "+", w, alloc),
        .FSub, .ISub => try emitBinOp(module, names, inst, "-", w, alloc),
        .FMul, .IMul => try emitBinOp(module, names, inst, "*", w, alloc),
        .FDiv, .SDiv, .UDiv => try emitBinOp(module, names, inst, "/", w, alloc),
        .FMod => {
            // GLSL mod(x,y) = x - y * floor(x/y) — floor-based, NOT truncation
            // HLSL % and fmod() both use truncation, so we must inline the floor formula
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const result_name = names.get(inst.words[2]) orelse "v";
            const lhs = names.get(inst.words[3]) orelse "a";
            const rhs = names.get(inst.words[4]) orelse "b";
            try w.print("    {s} {s} = {s} - {s} * floor({s} / {s});\n", .{ rt, result_name, lhs, rhs, lhs, rhs });
        },
        .UMod, .SRem, .SMod, .FRem => try emitBinOp(module, names, inst, "%", w, alloc),
        .ShiftLeftLogical => try emitBinOp(module, names, inst, "<<", w, alloc),
        .ShiftRightLogical => try emitBinOp(module, names, inst, ">>", w, alloc),

        .FNegate, .SNegate => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },

        .VectorTimesScalar, .MatrixTimesScalar => try emitBinOp(module, names, inst, "*", w, alloc),
        .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try emitCall(module, names, inst, "mul", w, alloc),
        .Dot => try emitCall(module, names, inst, "dot", w, alloc),
        .Transpose => try emitCall(module, names, inst, "transpose", w, alloc),

        // Comparisons
        .FOrdEqual, .FUnordEqual, .IEqual => try emitBinOp(module, names, inst, "==", w, alloc),
        .FOrdNotEqual, .FUnordNotEqual, .INotEqual => try emitBinOp(module, names, inst, "!=", w, alloc),
        .FOrdLessThan, .FUnordLessThan, .SLessThan, .ULessThan => try emitBinOp(module, names, inst, "<", w, alloc),
        .FOrdGreaterThan, .FUnordGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(module, names, inst, ">", w, alloc),
        .FOrdLessThanEqual, .FUnordLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(module, names, inst, "<=", w, alloc),
        .FOrdGreaterThanEqual, .FUnordGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(module, names, inst, ">=", w, alloc),

        .LogicalOr => try emitBinOp(module, names, inst, "||", w, alloc),
        .LogicalAnd => try emitBinOp(module, names, inst, "&&", w, alloc),
        .LogicalNot => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },

        .Select => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const cond_type = getTypeOf(module, inst.words[3]);
            const is_vec_cond = if (cond_type) |ct| blk: {
                const ct_inst = getDef(module, ct);
                break :blk ct_inst != null and ct_inst.?.op == .TypeVector;
            } else false;
            if (is_vec_cond) {
                // DXC requires select() for vector conditions
                try w.print("    {s} {s} = select({s}, {s}, {s});\n", .{
                    rt, names.get(inst.words[2]) orelse "v",
                    names.get(inst.words[3]) orelse "c",
                    names.get(inst.words[4]) orelse "t",
                    names.get(inst.words[5]) orelse "f",
                });
            } else {
                try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{
                    rt, names.get(inst.words[2]) orelse "v",
                    names.get(inst.words[3]) orelse "c",
                    names.get(inst.words[4]) orelse "t",
                    names.get(inst.words[5]) orelse "f",
                });
            }
        },

        .BitwiseOr => try emitBinOp(module, names, inst, "|", w, alloc),
        .BitwiseXor => try emitBinOp(module, names, inst, "^", w, alloc),
        .BitwiseAnd => try emitBinOp(module, names, inst, "&", w, alloc),
        .Not => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ~{s};\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitCount => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = countbits({s});\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .BitReverse => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = reversebits({s});\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        // OpBitFieldInsert: base, insert, offset, count. The spvBitfieldInsert helper is
        // uint-based; a signed result is cast back from the uint return (like spirv-cross).
        .BitFieldInsert => {
            if (inst.words.len < 7) return;
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const base = names.get(inst.words[3]) orelse "0";
            const insert = names.get(inst.words[4]) orelse "0";
            const offset = names.get(inst.words[5]) orelse "0";
            const count = names.get(inst.words[6]) orelse "0";
            // hlslType returns exactly "int[N]" (signed) or "uint[N]" (unsigned) for integer
            // types, and OpBitFieldInsert is integer-only — so startsWith("int") selects the
            // signed forms without ever matching the 'u'-prefixed unsigned ones.
            if (std.mem.startsWith(u8, rt, "int")) {
                try w.print("    {s} {s} = {s}(spvBitfieldInsert({s}, {s}, {s}, {s}));\n", .{ rt, rn, rt, base, insert, offset, count });
            } else {
                try w.print("    {s} {s} = spvBitfieldInsert({s}, {s}, {s}, {s});\n", .{ rt, rn, base, insert, offset, count });
            }
        },
        // OpBitFieldSExtract: value, offset, count → int-based helper (sign-extends).
        .BitFieldSExtract => {
            if (inst.words.len < 6) return;
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = spvBitfieldSExtract({s}, {s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0", names.get(inst.words[5]) orelse "0" });
        },
        // OpBitFieldUExtract: value, offset, count → uint-based helper (zero-extends).
        .BitFieldUExtract => {
            if (inst.words.len < 6) return;
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = spvBitfieldUExtract({s}, {s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0", names.get(inst.words[4]) orelse "0", names.get(inst.words[5]) orelse "0" });
        },

        // Conversions
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s})({s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0",
            });
        },
        .Bitcast => {
            // OpBitcast: reinterpret bits (float ↔ int/uint)
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = names.get(inst.words[3]) orelse "0";
            const result = names.get(inst.words[2]) orelse "v";
            // HLSL: asfloat() for int→float, asint() for float→int
            if (std.mem.indexOf(u8, rt, "float") != null) {
                try w.print("    {s} {s} = asfloat({s});\n", .{ rt, result, val });
            } else {
                try w.print("    {s} {s} = asint({s});\n", .{ rt, result, val });
            }
        },
        .UConvert, .SConvert, .FConvert => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s})({s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0",
            });
        },

        // Composites
        .CompositeConstruct => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}(", .{ rt, names.get(inst.words[2]) orelse "v", rt });
            for (inst.words[3..], 0..) |cid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(cid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .CompositeExtract => {
            // Skip if source is a decomposed std450 struct (FrexpStruct/ModfStruct)
            if (inst.words.len > 3) {
                const src_def = getDef(module, inst.words[3]);
                if (src_def) |sd| {
                    if (sd.op == .ExtInst and sd.words.len >= 5) {
                        const ext_op = sd.words[4];
                        if (ext_op == 52 or ext_op == 36) return;
                    }
                }
            }
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{ rt, names.get(inst.words[2]) orelse "v", comp });
            // Determine if parent is vector (use .xyzw) or struct (use _mN)
            var parent_type = getTypeOf(module, inst.words[3]);

            for (inst.words[4..]) |index| {
                // Update parent_type for each index level
                const current_parent = parent_type;
                const is_current_vec = if (current_parent) |pt| blk: {
                    const pt_inst = getDef(module, pt);
                    break :blk pt_inst != null and pt_inst.?.op == .TypeVector;
                } else false;

                if (is_current_vec) {
                    try w.writeAll(switch (index) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                } else {
                    // Use named member for structs; matrices index a column via [n].
                    var used_name = false;
                    if (current_parent) |pt| {
                        const pt_inst = getDef(module, pt);
                        if (pt_inst) |pi| {
                            if (pi.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = hlslGetMemberName(module, pt, @intCast(index), &mname_buf);
                                try w.print(".{s}", .{mname});
                                used_name = true;
                            } else if (pi.op == .TypeMatrix) {
                                // SPIR-V OpCompositeExtract/Insert on a matrix
                                // selects a column (column-major). glslpp emits
                                // matrices column-by-column, so HLSL `m[n]` yields
                                // that same stored column vector. `._mN` is invalid
                                // HLSL matrix syntax and DXC rejects it.
                                try w.print("[{d}]", .{index});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try w.print("._m{d}", .{index});
                }
                // Advance parent_type for next index level
                if (current_parent) |pt| {
                    const pt_inst = getDef(module, pt);
                    if (pt_inst) |pi| {
                        if (pi.op == .TypeVector) {
                            parent_type = pi.words[2];
                        } else if (pi.op == .TypeStruct and index + 2 < pi.words.len) {
                            parent_type = pi.words[index + 2];
                        } else if (pi.op == .TypeArray or pi.op == .TypeMatrix) {
                            parent_type = pi.words[2];
                        } else {
                            parent_type = null;
                        }
                    }
                }
            }
            try w.writeAll(";\n");
        },
        .CompositeInsert => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const rname = names.get(inst.words[2]) orelse "v";
            const object = names.get(inst.words[3]) orelse "obj";
            const composite = names.get(inst.words[4]) orelse "comp";
            // Copy composite, then overwrite the indexed member with object
            try w.print("    {s} {s} = {s};\n", .{ rt, rname, composite });
            // Determine if parent is vector (use .xyzw) or struct (use _mN)
            var parent_type = getTypeOf(module, inst.words[4]);
            try w.print("    {s}", .{rname});
            for (inst.words[5..]) |index| {
                const current_parent = parent_type;
                const is_current_vec = if (current_parent) |pt| blk: {
                    const pt_inst = getDef(module, pt);
                    break :blk pt_inst != null and pt_inst.?.op == .TypeVector;
                } else false;

                if (is_current_vec) {
                    try w.writeAll(switch (index) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                } else {
                    // Use named member for structs; matrices index a column via [n].
                    var used_name = false;
                    if (current_parent) |pt| {
                        const pt_inst = getDef(module, pt);
                        if (pt_inst) |pi| {
                            if (pi.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = hlslGetMemberName(module, pt, @intCast(index), &mname_buf);
                                try w.print(".{s}", .{mname});
                                used_name = true;
                            } else if (pi.op == .TypeMatrix) {
                                // SPIR-V OpCompositeExtract/Insert on a matrix
                                // selects a column (column-major). glslpp emits
                                // matrices column-by-column, so HLSL `m[n]` yields
                                // that same stored column vector. `._mN` is invalid
                                // HLSL matrix syntax and DXC rejects it.
                                try w.print("[{d}]", .{index});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try w.print("._m{d}", .{index});
                }
                // Advance parent_type for next index level
                if (current_parent) |pt| {
                    const pt_inst = getDef(module, pt);
                    if (pt_inst) |pi| {
                        if (pi.op == .TypeVector) {
                            parent_type = pi.words[2];
                        } else if (pi.op == .TypeStruct and index + 2 < pi.words.len) {
                            parent_type = pi.words[index + 2];
                        } else if (pi.op == .TypeArray or pi.op == .TypeMatrix) {
                            parent_type = pi.words[2];
                        } else {
                            parent_type = null;
                        }
                    }
                }
            }
            try w.print(" = {s};\n", .{object});
        },
        .VectorShuffle => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "v1";
            const v2 = names.get(inst.words[4]) orelse "v2";
            const v1_type = getTypeOf(module, inst.words[3]);
            const v1_len: u32 = if (v1_type) |vt| blk: {
                const vi = getDef(module, vt);
                break :blk if (vi != null and vi.?.op == .TypeVector) vi.?.words[3] else 4;
            } else 4;

            try w.print("    {s} {s} = {s}(", .{ rt, names.get(inst.words[2]) orelse "v", rt });
            for (inst.words[5..], 0..) |sel, i| {
                if (i > 0) try w.writeAll(", ");
                if (sel < v1_len) {
                    try w.print("{s}{s}", .{ v1, swizzleChar(sel) });
                } else {
                    try w.print("{s}{s}", .{ v2, swizzleChar(sel - v1_len) });
                }
            }
            try w.writeAll(");\n");
        },

        // Derivatives
        .DPdx, .DPdxFine, .DPdxCoarse => try emitCall(module, names, inst, "ddx", w, alloc),
        .DPdy, .DPdyFine, .DPdyCoarse => try emitCall(module, names, inst, "ddy", w, alloc),
        .Fwidth, .FwidthFine, .FwidthCoarse => {
            const arg = if (inst.words.len > 3) names.get(inst.words[3]) orelse "0" else "0";
            const result = if (inst.words.len > 2) names.get(inst.words[2]) orelse "v" else "v";
            const rt = if (inst.words.len > 1) hlslType(module, inst.words[1], names, alloc) catch "float" else "float";
            try w.print("    {s} {s} = abs(ddx({s})) + abs(ddy({s}));\n", .{ rt, result, arg, arg });
        },

        .All => try emitCall(module, names, inst, "all", w, alloc),
        .Any => try emitCall(module, names, inst, "any", w, alloc),
        .IsNan => try emitCall(module, names, inst, "isnan", w, alloc),
        .IsInf => try emitCall(module, names, inst, "isinf", w, alloc),

        // GLSLstd450
        .ExtInst => {
            if (inst.words.len < 5) return;
            const instruction = inst.words[4];
            // FrexpStruct (52) and ModfStruct (36) return structs — decompose to two-arg form
            if (instruction == 52 or instruction == 36) {
                const result_id = inst.words[2];
                const input_name = names.get(inst.words[5]) orelse "x";
                const func_name: []const u8 = if (instruction == 52) "frexp" else "modf";
                var fract_name: []const u8 = "_fract";
                var second_name: []const u8 = "_second";
                var fract_type: []const u8 = "float";
                var second_type: []const u8 = "int";
                // Find downstream CompositeExtracts for member names/types
                {
                    var j: usize = 0;
                    for (module.instructions, 0..) |mi, i| {
                        if (mi.op == .ExtInst and mi.words.len >= 3 and mi.words[2] == result_id) {
                            j = i + 1;
                            break;
                        }
                    }
                    while (j < module.instructions.len) : (j += 1) {
                        const ni = module.instructions[j];
                        if (ni.op == .FunctionEnd) break;
                        if (ni.op == .CompositeExtract and ni.words.len >= 5 and ni.words[3] == result_id) {
                            const member_idx = ni.words[4];
                            const ce_name = names.get(ni.words[2]) orelse "v";
                            const ce_type = try hlslType(module, ni.words[1], names, alloc);
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
                try w.print("    {s} {s};\n", .{ second_type, second_name });
                try w.print("    {s} {s} = {s}({s}, {s});\n", .{ fract_type, fract_name, func_name, input_name, second_name });
            } else {
                try emitStd450(module, names, inst, instruction, w, alloc);
            }
        },

        // Texture ops
        .SampledImage => {
            const result_id = inst.words[2];
            const img_name = names.get(inst.words[3]) orelse "tex";
            const sampler_name = names.get(inst.words[4]) orelse "sampler";
            const pair = try std.fmt.allocPrint(alloc, "{s},{s}", .{ img_name, sampler_name });
            if (try names.fetchPut(result_id, pair)) |old| alloc.free(old.value);
        },
        .ImageSampleImplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.Sample({s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord,
            });
        },
        // OpImageQueryLod (textureQueryLod): SampledImage, Coordinate → result vec2.
        // HLSL Texture.CalculateLevelOfDetail(sampler, coord) returns the clamped LOD as a
        // scalar; spirv-cross splats it to the vec2 result (.xx) for both components. (The
        // .y component — the unclamped LOD in GLSL — is thereby approximated as the clamped
        // value, matching spirv-cross; CalculateLevelOfDetailUnclamped would be exact.)
        .ImageQueryLod => {
            if (inst.words.len < 5) return;
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.CalculateLevelOfDetail({s}, {s}).xx;\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord,
            });
        },
        .ImageSampleDrefImplicitLod => {
            // Shadow texture: HLSL uses .SampleCmp(sampler, coord, compare)
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.SampleCmp({s}, {s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, dref,
            });
        },
        .ImageSampleDrefExplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.SampleCmpLevelZero({s}, {s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, dref,
            });
        },
        .ImageSampleProjImplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            // Projected sample: divide xy by last component
            // Determine coordinate type to use correct swizzle (.z for vec3, .w for vec4)
            const coord_type = getTypeOf(module, inst.words[4]);
            const last_swizzle: []const u8 = if (coord_type) |ct| blk: {
                const ct_inst = getDef(module, ct);
                if (ct_inst) |ci| {
                    if (ci.op == .TypeVector and ci.words.len > 3) {
                        const vec_len = ci.words[3];
                        break :blk switch (vec_len) {
                            3 => ".z",
                            4 => ".w",
                            else => ".z",
                        };
                    }
                }
                break :blk ".z";
            } else ".z";
            try w.print("    {s} {s} = {s}.Sample({s}, {s}.xy / {s}{s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, last_swizzle,
            });
        },
        .ImageSampleProjDrefImplicitLod => {
            // Projected shadow: SampleCmp with manual projection
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            const coord_type = getTypeOf(module, inst.words[4]);
            const last_swizzle: []const u8 = if (coord_type) |ct| blk: {
                const ct_inst = getDef(module, ct);
                if (ct_inst) |ci| {
                    if (ci.op == .TypeVector and ci.words.len > 3) {
                        break :blk switch (ci.words[3]) { 3 => ".z", 4 => ".w", else => ".z" };
                    }
                }
                break :blk ".z";
            } else ".z";
            try w.print("    {s} {s} = {s}.SampleCmp({s}, {s}.xy / {s}{s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, last_swizzle, dref,
            });
        },
        .ImageSampleProjDrefExplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            const coord_type = getTypeOf(module, inst.words[4]);
            const last_swizzle: []const u8 = if (coord_type) |ct| blk: {
                const ct_inst = getDef(module, ct);
                if (ct_inst) |ci| {
                    if (ci.op == .TypeVector and ci.words.len > 3) {
                        break :blk switch (ci.words[3]) { 3 => ".z", 4 => ".w", else => ".z" };
                    }
                }
                break :blk ".z";
            } else ".z";
            try w.print("    {s} {s} = {s}.SampleCmpLevelZero({s}, {s}.xy / {s}{s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, last_swizzle, dref,
            });
        },
        .ImageSampleProjExplicitLod => {
            // Projected explicit LOD: SampleLevel with manual projection
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}.xy / {s}.w, {s});\n", .{
                        rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, names.get(inst.words[off]) orelse "0",
                    });
                } else {
                    try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}.xy / {s}.w, 0);\n", .{
                        rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord,
                    });
                }
            } else {
                try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}.xy / {s}.w, 0);\n", .{
                    rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord,
                });
            }
        },
        .ImageSampleExplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            // Find image operands: Bit 0=Bias, Bit 1=Lod, Bit 2=Grad, Bit 3=ConstOffset, Bit 4=Offset
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1; // skip Bias
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    // Lod operand
                    const lod = names.get(inst.words[off]) orelse "0";
                    try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}, {s});\n", .{
                        rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, lod,
                    });
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    // Grad operands (dx, dy)
                    const dx = names.get(inst.words[off]) orelse "0";
                    const dy = names.get(inst.words[off + 1]) orelse "0";
                    try w.print("    {s} {s} = {s}.SampleGrad({s}, {s}, {s}, {s});\n", .{
                        rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, dx, dy,
                    });
                } else {
                    // Fallback: Sample with lod=0
                    try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}, 0);\n", .{
                        rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord,
                    });
                }
            } else {
                try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}, 0);\n", .{
                    rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord,
                });
            }
        },
        .ImageFetch => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const coord_name = names.get(inst.words[4]) orelse "0";
            const tex_name = names.get(inst.words[3]) orelse "tex";
            // Check if this is a buffer texture — Buffer.Load takes scalar int
            var is_buffer_tex = false;
            if (getDef(module, inst.words[4])) |coord_inst| {
                if (coord_inst.op == .Constant) {
                    is_buffer_tex = true;
                }
            }
            // Check for multisampled texture — Texture2DMS.Load(int2, sampleIndex)
            // ImageFetch for MS textures has Sample operand after coordinate
            // SPIR-V Image Operands: word[5] has bitmask, Sample = 0x20
            var is_ms_tex = false;
            var sample_idx: []const u8 = "0";
            if (inst.words.len > 5) {
                // Check if word[5] is the Image Operands bitmask (not a result ID)
                // Sample bit = 0x20
                const operands_mask = inst.words[5];
                if (operands_mask & 0x40 != 0 and inst.words.len > 6) {
                    // Has Sample operand — this is a multisampled fetch
                    is_ms_tex = true;
                    sample_idx = names.get(inst.words[6]) orelse "0";
                }
            }
            if (is_buffer_tex) {
                try w.print("    {s} {s} = {s}.Load({s});\n", .{
                    rt, names.get(inst.words[2]) orelse "v", tex_name, coord_name,
                });
            } else if (is_ms_tex) {
                try w.print("    {s} {s} = {s}.Load({s}, {s});\n", .{
                    rt, names.get(inst.words[2]) orelse "v", tex_name, coord_name, sample_idx,
                });
            } else {
                try w.print("    {s} {s} = {s}.Load(int3({s}, 0));\n", .{
                    rt, names.get(inst.words[2]) orelse "v", tex_name, coord_name,
                });
            }
        },
        .ImageGather => {
            // textureGatherOffsets lowers to OpImageGather with the ConstOffsets
            // image operand (mask bit 0x20 at word[6], the 4-offset array id at
            // word[7]). HLSL's `.Gather*` intrinsics take no per-texel offset
            // array, so emitting a plain `.GatherGreen` here would SILENTLY DROP
            // the offsets (silent-wrong). Fail loudly instead; per-texel
            // emulation (4 offset gathers) is a follow-up.
            if (inst.words.len > 6 and (inst.words[6] & 0x20) != 0) {
                return error.UnsupportedImageOperands;
            }
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            // OpImageGather component is word[5] (default 0 = Red)
            const comp_val: u32 = if (inst.words.len > 5) blk: {
                const def = getDef(module, inst.words[5]) orelse break :blk 0;
                if (def.op == .Constant and def.words.len > 3) break :blk def.words[3];
                break :blk 0;
            } else 0;
            const gather_swiz = switch (comp_val) {
                0 => "GatherRed",
                1 => "GatherGreen",
                2 => "GatherBlue",
                3 => "GatherAlpha",
                else => "GatherRed",
            };
            try w.print("    {s} {s} = {s}.{s}({s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], gather_swiz, parts[1], coord,
            });
        },
        .ImageDrefGather => {
            // HLSL: tex.GatherCmp(sampler, coord, compare)
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.GatherCmp({s}, {s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, dref,
            });
        },
        .ImageQuerySizeLod => {
            // OpImageQuerySizeLod: result_type, result, image, lod
            // HLSL GetDimensions uses out params, not return value
            const img_name = names.get(inst.words[3]) orelse "tex";
            const lod = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            // Strip _sampler suffix to get texture name
            var tex_name: []const u8 = img_name;
            if (std.mem.endsWith(u8, img_name, "_sampler")) {
                tex_name = img_name[0..img_name.len - "_sampler".len];
            }
            const result_name = names.get(inst.words[2]) orelse "v";
            // Determine result rank from the result type (1=scalar, 2, or 3).
            const rt_inst = getDef(module, inst.words[1]);
            const rank: u32 = if (rt_inst) |rti| (if (rti.op == .TypeVector and rti.words.len > 3) rti.words[3] else 1) else 1;
            if (rank <= 1) {
                try w.print("    uint {s}_w, {s}_levels; {s}.GetDimensions({s}, {s}_w, {s}_levels);\n", .{ result_name, result_name, tex_name, lod, result_name, result_name });
                try w.print("    {s} {s} = {s}_w;\n", .{ try hlslType(module, inst.words[1], names, alloc), result_name, result_name });
            } else if (rank == 3) {
                // 3-component: 3D (w,h,depth) or arrayed (w,h,elements). HLSL
                // selects the GetDimensions overload by texture type, so the
                // third out-param carries depth or array length automatically.
                try w.print("    uint {s}_w, {s}_h, {s}_d, {s}_levels; {s}.GetDimensions({s}, {s}_w, {s}_h, {s}_d, {s}_levels);\n", .{ result_name, result_name, result_name, result_name, tex_name, lod, result_name, result_name, result_name, result_name });
                try w.print("    int3 {s} = int3({s}_w, {s}_h, {s}_d);\n", .{ result_name, result_name, result_name, result_name });
            } else {
                try w.print("    uint {s}_w, {s}_h, {s}_levels; {s}.GetDimensions({s}, {s}_w, {s}_h, {s}_levels);\n", .{ result_name, result_name, result_name, tex_name, lod, result_name, result_name, result_name });
                try w.print("    int2 {s} = int2({s}_w, {s}_h);\n", .{ result_name, result_name, result_name });
            }
        },
        .ImageQuerySize => {
            // OpImageQuerySize: result_type, result, image (no lod)
            // HLSL GetDimensions uses out params
            const img_name = names.get(inst.words[3]) orelse "tex";
            var tex_name: []const u8 = img_name;
            if (std.mem.endsWith(u8, img_name, "_sampler")) {
                tex_name = img_name[0..img_name.len - "_sampler".len];
            }
            const result_name = names.get(inst.words[2]) orelse "v";
            const rt_inst = getDef(module, inst.words[1]);
            const rank: u32 = if (rt_inst) |rti| (if (rti.op == .TypeVector and rti.words.len > 3) rti.words[3] else 1) else 1;
            if (rank <= 1) {
                try w.print("    uint {s}_w; {s}.GetDimensions({s}_w);\n", .{ result_name, tex_name, result_name });
                try w.print("    {s} {s} = {s}_w;\n", .{ try hlslType(module, inst.words[1], names, alloc), result_name, result_name });
            } else if (rank == 3) {
                // 3-component: 3D (w,h,depth) or arrayed (w,h,elements). The
                // RWTexture3D/RWTexture2DArray GetDimensions overload fills the
                // third out-param with depth or array length respectively.
                // Texture2DMSArray's only overload additionally requires a
                // NumberOfSamples out-param, so MS arrays query a 4th value.
                if (imageValueIsMultisampled(module, inst.words[3])) {
                    try w.print("    uint {s}_w, {s}_h, {s}_d, {s}_samples; {s}.GetDimensions({s}_w, {s}_h, {s}_d, {s}_samples);\n", .{ result_name, result_name, result_name, result_name, tex_name, result_name, result_name, result_name, result_name });
                } else {
                    try w.print("    uint {s}_w, {s}_h, {s}_d; {s}.GetDimensions({s}_w, {s}_h, {s}_d);\n", .{ result_name, result_name, result_name, tex_name, result_name, result_name, result_name });
                }
                try w.print("    int3 {s} = int3({s}_w, {s}_h, {s}_d);\n", .{ result_name, result_name, result_name, result_name });
            } else {
                try w.print("    uint {s}_w, {s}_h; {s}.GetDimensions({s}_w, {s}_h);\n", .{ result_name, result_name, tex_name, result_name, result_name });
                try w.print("    int2 {s} = int2({s}_w, {s}_h);\n", .{ result_name, result_name, result_name });
            }
        },
        .ImageRead => {
            // OpImageRead: result_type, result, image, coordinate
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const img = names.get(inst.words[3]) orelse "image";
            const coord = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            try w.print("    {s} {s} = {s}[{s}];\n", .{
                rt, names.get(inst.words[2]) orelse "v", img, coord,
            });
        },

        // Control flow
        .Kill => try w.writeAll("    discard;\n"),
        .Unreachable => {}, // no-op
        .BeginInvocationInterlockEXT => {}, // no-op in HLSL (use rasterizerOrdered views)
        .EndInvocationInterlockEXT => {},
        .ReadClockKHR => {
            // HLSL has no direct clock() equivalent. Emit a stub with unique name.
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse blk: {
                const uname = try std.fmt.allocPrint(alloc, "_clk_{d}", .{inst.words[2]});
                break :blk uname;
            };
            try w.print("    {s} {s} = ({s})0; // ReadClockKHR stub\n", .{ rtt, rn, rtt });
        },
        .ImageWrite => {
            // OpImageWrite: image, coordinate, texel
            const img = names.get(inst.words[1]) orelse "image";
            const coord = if (inst.words.len > 2) names.get(inst.words[2]) orelse "0" else "0";
            const texel = if (inst.words.len > 3) names.get(inst.words[3]) orelse "0" else "0";
            try w.print("    {s}[{s}] = {s};\n", .{ img, coord, texel });
        },
        // Atomics: Interlocked* in HLSL
        .AtomicIAdd => {
            // OpAtomicIAdd: result_type, result, pointer, memory_scope, semantics, value
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedAdd({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedAdd({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicISub => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1" else "1";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedAdd({s}, -({s}));\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedAdd({s}[{s}], -({s}));\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicSMin, .AtomicUMin => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedMin({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedMin({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicSMax, .AtomicUMax => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedMax({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedMax({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicAnd => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedAnd({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedAnd({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicOr => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedOr({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedOr({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicXor => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedXor({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedXor({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicExchange => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedExchange({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedExchange({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .AtomicCompareExchange => {
            // OpAtomicCompareExchange: result_type, result, pointer, sc1, sem1, sem2, value, comparator
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
            const cmp = if (inst.words.len > 8) names.get(inst.words[8]) orelse "0" else "0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedCompareExchange({s}, {s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, cmp, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedCompareExchange({s}[{s}], {s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, cmp, val }),
            }
        },
        .AtomicFAddEXT => {
            // OpAtomicFAddEXT: floating-point atomic add
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const val = if (inst.words.len > 6) names.get(inst.words[6]) orelse "1.0" else "1.0";
            switch (classifyHlslAtomicPtr(module, names, inst.words[3])) {
                .ssbo => |ptr| try w.print("    {s} {s}; InterlockedAdd({s}, {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", ptr, val }),
                .image => |p| try w.print("    {s} {s}; InterlockedAdd({s}[{s}], {s});\n", .{ rt, names.get(inst.words[2]) orelse "v", p.img, p.coord, val }),
            }
        },
        .Return => {
            // Skip bare return in fragment/vertex entry — we emit the output return at function end
            if (is_fragment or is_vertex) {} else {
                try w.writeAll("    return;\n");
            }
        },
        .ReturnValue => {
            const val_id = inst.words[1];
            // If returning the output variable in a fragment entry, skip it
            // (we handle the return at function end)
            if (is_fragment and output_var_id != null and val_id == output_var_id.?) {} else {
                try w.print("    return {s};\n", .{names.get(val_id) orelse "0"});
            }
        },
        // Control flow — reconstruct structured flow from SPIR-V branch-based IR
        .SelectionMerge => {}, // consumed by BranchConditional handler
        .LoopMerge => {}, // consumed by branch handler
        .Label => {}, // basic block boundary — handled by control flow tracking

        .Branch => {
            // Unconditional branch — only meaningful for loop back-edges
            // For straight-line code, this just goes to the next block
        },

        .BranchConditional => {
            // Handled by emitBody's structured control flow reconstruction
        },

        .FunctionCall => {
            const func_id_call = inst.words[3];
            const func_name_call = names.get(func_id_call) orelse "func";
            const result_name = names.get(inst.words[2]) orelse "v";

            // Check if return type is void
            const return_type_id = inst.words[1];
            const is_void_call = blk: {
                const rt_inst = getDef(module, return_type_id);
                break :blk rt_inst != null and rt_inst.?.op == .TypeVoid;
            };

            if (is_void_call) {
                // Void function call — no assignment
                try w.print("    {s}(", .{func_name_call});
            } else {
                const rt = try hlslType(module, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}(", .{ rt, result_name, func_name_call });
            }
            for (inst.words[4..], 0..) |arg_id, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(arg_id) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .ControlBarrier => try w.writeAll("    GroupMemoryBarrierWithGroupSync();\n"),
        .MemoryBarrier => try w.writeAll("    DeviceMemoryBarrier();\n"),
        .ImageTexelPointer => {
            // No code emission needed — result used by atomic ops
        },

        // Subgroup operations → HLSL Wave* intrinsics (SM6.0+)
        .GroupNonUniformElect => {
            const rn = names.get(inst.words[2]) orelse "v";
            try w.print("    bool {s} = WaveIsFirstLane();\n", .{rn});
        },
        .GroupNonUniformAll => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveAllTrue({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformAny => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveAnyTrue({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformAllEqual => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveAllEqual({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBroadcast => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = WaveReadLaneAt({s}, {s});\n", .{rtt, rn, val, lane});
        },
        .GroupNonUniformBroadcastFirst => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveReadLaneFirst({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBallot => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveBallot({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformShuffle => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const lane = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = WaveReadLaneAt({s}, {s});\n", .{rtt, rn, val, lane});
        },
        .GroupNonUniformShuffleXor => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const mask = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = WaveReadLaneAt({s}, gl_SubgroupInvocationID ^ {s});\n", .{rtt, rn, val, mask});
        },
        .GroupNonUniformShuffleUp => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = WaveReadLaneAt({s}, gl_SubgroupInvocationID - {s});\n", .{rtt, rn, val, delta});
        },
        .GroupNonUniformShuffleDown => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            const delta = names.get(inst.words[5]) orelse "0";
            try w.print("    {s} {s} = WaveReadLaneAt({s}, gl_SubgroupInvocationID + {s});\n", .{rtt, rn, val, delta});
        },
        .GroupNonUniformIAdd => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveSum({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformFAdd => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveSum({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformIMul => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveProduct({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformFMul => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveProduct({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformSMin, .GroupNonUniformUMin, .GroupNonUniformFMin => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveMin({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformSMax, .GroupNonUniformUMax, .GroupNonUniformFMax => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveMax({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseAnd => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveBitAnd({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseOr => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveBitOr({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformBitwiseXor => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveBitXor({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformLogicalAnd => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveAllTrue({s});\n", .{rtt, rn, val});
        },
        .GroupNonUniformLogicalOr => {
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[4]) orelse "x";
            try w.print("    {s} {s} = WaveActiveAnyTrue({s});\n", .{rtt, rn, val});
        },
        .SubgroupAllKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = WaveActiveAllTrue({s});\n", .{rn, val});
        },
        .SubgroupAnyKHR => {
            const rn = names.get(inst.words[2]) orelse "v";
            const val = names.get(inst.words[3]) orelse "x";
            try w.print("    bool {s} = WaveActiveAnyTrue({s});\n", .{rn, val});
        },

        // Skip non-code-emitting ops
        .Constant, .ConstantTrue, .ConstantFalse, .ConstantComposite, .SpecConstant, .Undef => {},
        .Function, .FunctionParameter, .FunctionEnd => {},
        .Source, .Name, .MemberName => {},
        .Nop => {},
        .VectorExtractDynamic => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}[{s}];\n", .{
                rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "v", names.get(inst.words[4]) orelse "0",
            });
        },
        .OpImage => {
            // Extract image from sampled image — just use the name
            if (inst.words.len > 3) {
                const si_name = names.get(inst.words[3]) orelse "tex,tex_sampler";
                const parts = splitPair(si_name);
                const img_name = try alloc.dupe(u8, parts[0]);
                if (try names.fetchPut(inst.words[2], img_name)) |old| alloc.free(old.value);
            }
        },

        else => {
            // Mesh/task shader ops
            if (inst.op == .SetMeshOutputsEXT) {
                if (inst.words.len >= 3) {
                    const vc = idToExpr(module, names, inst.words[1], alloc);
                    const pc = idToExpr(module, names, inst.words[2], alloc);
                    try w.print("    SetMeshOutputCounts({s}, {s});\n", .{vc, pc});
                }
                return;
            }
            if (inst.op == .EmitMeshTasksEXT) {
                if (inst.words.len >= 5) {
                    const x = idToExpr(module, names, inst.words[1], alloc);
                    const y = idToExpr(module, names, inst.words[2], alloc);
                    const z = idToExpr(module, names, inst.words[3], alloc);
                    const p = idToExpr(module, names, inst.words[4], alloc);
                    try w.print("    DispatchMesh({s}, {s}, {s}, {s});\n", .{x, y, z, p});
                }
                return;
            }
            // KHR_ray_tracing ops
            if (inst.op == .TraceRayKHR) {
                if (inst.words.len >= 12) {
                    const accel = idToExpr(module, names, inst.words[1], alloc);
                    const flags = idToExpr(module, names, inst.words[2], alloc);
                    const mask = idToExpr(module, names, inst.words[3], alloc);
                    const sbt_off = idToExpr(module, names, inst.words[4], alloc);
                    const sbt_stride = idToExpr(module, names, inst.words[5], alloc);
                    const miss = idToExpr(module, names, inst.words[6], alloc);
                    const origin = idToExpr(module, names, inst.words[7], alloc);
                    const t_min = idToExpr(module, names, inst.words[8], alloc);
                    const dir = idToExpr(module, names, inst.words[9], alloc);
                    const t_max = idToExpr(module, names, inst.words[10], alloc);
                    const payload = idToExpr(module, names, inst.words[11], alloc);
                    try w.print("    TraceRay({s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s}, {s});\n", .{accel, flags, mask, sbt_off, sbt_stride, miss, origin, t_min, dir, t_max, payload});
                }
                return;
            }
            if (inst.op == .ReportIntersectionKHR) {
                if (inst.words.len >= 5) {
                    const hit_t = idToExpr(module, names, inst.words[3], alloc);
                    const hit_kind = idToExpr(module, names, inst.words[4], alloc);
                    try w.print("    ReportHit({s}, {s});\n", .{hit_t, hit_kind});
                }
                return;
            }
            if (inst.op == .IgnoreIntersectionKHR) {
                try w.writeAll("    IgnoreHit();\n");
                return;
            }
            if (inst.op == .TerminateRayKHR) {
                try w.writeAll("    AcceptHitAndEndSearch();\n");
                return;
            }
            if (inst.op == .ExecuteCallableKHR) {
                if (inst.words.len >= 3) {
                    const sbt = idToExpr(module, names, inst.words[1], alloc);
                    const data = idToExpr(module, names, inst.words[2], alloc);
                    try w.print("    CallShader({s}, {s});\n", .{sbt, data});
                }
                return;
            }
            try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
        },
    }
}

fn swizzleChar(index: u32) []const u8 {
    return switch (index) {
        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
    };
}

fn hlslGetMemberName(module: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    return common.commonGetMemberName(module.instructions, struct_id, member_idx, buf, "_m");
}

fn splitPair(pair: []const u8) [2][]const u8 {
    if (std.mem.indexOfScalar(u8, pair, ',')) |comma| {
        return .{ pair[0..comma], pair[comma + 1 ..] };
    }
    return .{ pair, pair };
}

fn writeResolvePointer(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, w: anytype) !void {
    // First check if there's a pre-mapped name for this ID
    if (names.get(ptr_id)) |mapped_name| {
        // If the mapped name doesn't look like a raw access chain expression, use it directly
        const inst = getDef(module, ptr_id);
        if (inst != null and inst.?.op == .AccessChain) {
            // Check if the mapped name was set by our builtin [0] stripping filter
            // by checking if it's different from what buildAccessExpr would produce
            const base_name = names.get(inst.?.words[3]) orelse "";
            // If the mapped name equals the base name, it was stripped
            if (std.mem.eql(u8, mapped_name, base_name)) {
                try w.writeAll(mapped_name);
                return;
            }
        }
    }
    const inst = getDef(module, ptr_id) orelse {
        try w.writeAll(names.get(ptr_id) orelse "var");
        return;
    };
    if (inst.op == .AccessChain) {
        try writeAccessExpr(module, names, inst.words[3], inst.words[4..], w);
        return;
    }
    try w.writeAll(names.get(ptr_id) orelse "var");
}

/// True for the two GLSL mesh-shader builtin names whose stores must be
/// routed through the entry-point signature parameters rather than emitted
/// as struct fields or bare l-values.
fn isMeshBuiltinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "gl_MeshPerVertexEXT") or
        std.mem.eql(u8, name, "gl_PrimitiveTriangleIndicesEXT") or
        std.mem.eql(u8, name, "gl_PrimitiveLineIndicesEXT") or
        std.mem.eql(u8, name, "gl_PrimitivePointIndicesEXT");
}

/// Parse a `__mesh_route__<base>[.<member>]` sentinel name set by the mesh
/// entry-point preamble (see spirvToHLSL, "M5.2 v2.c — body store routing").
/// Returns {base, member?} on a hit, null otherwise. `member` includes no
/// leading dot — the caller writes it back literally.
fn parseMeshRoute(name: []const u8) ?struct { base: []const u8, member: ?[]const u8 } {
    const prefix = "__mesh_route__";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        return .{ .base = rest[0..dot], .member = rest[dot + 1 ..] };
    }
    return .{ .base = rest, .member = null };
}

/// True if struct member `member_index` of `struct_id` carries the SPIR-V
/// RowMajor decoration (4). The default (ColMajor=5, or no decoration) is
/// false. A row-major matrix is stored as the row-major byte layout of the
/// logical matrix M; see `emitStructMembers` (storage qualifier) and
/// `findUniformMatrixColumnAccess` (transposed read).
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

/// True if `type_id` is a NON-square matrix (column count != row count). A
/// row-major non-square matrix needs swapped HLSL dimensions and a layout we
/// don't yet implement; the declaration emitter rejects it with an honest error
/// instead of emitting a column-major-shaped member (silent-wrong).
fn matrixIsNonSquare(module: *const ParsedModule, type_id: u32) bool {
    const mt = getDef(module, type_id) orelse return false;
    if (mt.op != .TypeMatrix) return false;
    const colvec = getDef(module, mt.words[2]) orelse return false;
    if (colvec.op != .TypeVector) return false;
    return mt.words[3] != colvec.words[3]; // cols != rows
}

/// True for a Uniform-storage (cbuffer/UBO) block variable — excludes SSBOs,
/// whose access is rewritten through the `__ssbo_buf__` sentinel and a separate
/// RWStructuredBuffer code path. Used to scope the cbuffer matrix-column
/// transpose fix to genuine UBO matrices.
fn isUniformBlockVar(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32) bool {
    if (std.mem.startsWith(u8, names.get(id) orelse "", "__ssbo_buf__")) return false;
    const inst = getDef(module, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        return sc == .Uniform;
    }
    return false;
}

const UniformMatrixAccess = struct { boundary: usize, matrix_tid: u32 };

/// If `indices` (rooted at a Uniform/cbuffer variable `base_id`) selects a
/// COLUMN (or deeper) out of a matrix, return where the matrix selection ends
/// (`boundary`: `indices[0..boundary+1]` produces the matrix; `indices[boundary+1..]`
/// is the column/element tail). glslpp stores a cbuffer matrix as the logical
/// matrix M (its `mul(M, v)` operand order requires it, dxc->spirv-cross
/// round-trip proven), but HLSL `m[i]` returns ROW i while GLSL/SPIR-V `m[i]` is
/// COLUMN i — so a column read must be emitted as `transpose(M)[i]`. The matrix
/// may be the top-level block member OR an array element of it (`a.mats[k][i]`).
///
/// CRITICAL scope: only the TOP-LEVEL block member (selected by `indices[0]`)
/// receives the `row_major` storage qualifier in `emitStructMembers`, so only
/// its matrices are stored as the logical M (where transpose is correct). A
/// matrix inside a NESTED struct (`a.s.m`) is emitted bare, so for a row_major
/// block it is stored as Mᵀ and reads correctly WITHOUT transpose — transposing
/// it would be silent-wrong. We therefore refuse to descend into a nested struct
/// (a TypeStruct at index position > 0). Nested-struct matrices are a documented
/// limitation (their column_major reads remain a pre-existing, separate gap).
///
/// Returns null for a whole-matrix load (no index INTO the matrix) — that feeds
/// `mul` and must stay untransposed — and for non-square matrices (row_major
/// non-square is rejected at declaration; non-square column_major is a separate
/// pre-existing gap).
fn findUniformMatrixColumnAccess(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32) ?UniformMatrixAccess {
    if (!isUniformBlockVar(module, names, base_id)) return null;
    var cur_type: ?u32 = resolvePointeeType(module, base_id);
    for (indices, 0..) |index_id, i| {
        const tid = cur_type orelse return null;
        const ti = getDef(module, tid) orelse return null;
        // `cur_type` is what `indices[i]` indexes. If it is a matrix, then
        // `indices[i]` selects a COLUMN and `indices[0..i]` produced the matrix.
        if (ti.op == .TypeMatrix) {
            if (i == 0) return null; // matrix must be reached via a block member
            if (matrixIsNonSquare(module, tid)) return null;
            return .{ .boundary = i - 1, .matrix_tid = tid };
        }
        if (ti.op == .TypeStruct) {
            // Only the top-level block struct is qualifier-eligible; bail on any
            // nested struct (see the doc-comment above — transposing a bare
            // nested row_major matrix would be silent-wrong).
            if (i != 0) return null;
            const def = getDef(module, index_id) orelse return null;
            if (def.op != .Constant or def.words.len <= 3) return null;
            const val = def.words[3];
            if (val + 2 >= ti.words.len) return null;
            cur_type = ti.words[val + 2];
        } else if (ti.op == .TypeArray) {
            cur_type = ti.words[2];
        } else {
            return null;
        }
    }
    return null;
}

/// Emit the access-chain indices that come AFTER a transposed cbuffer matrix: a
/// matrix-column index becomes `[col]` on the transposed value, and a
/// vector-element index becomes a `.xyzw` swizzle.
fn writeMatrixTail(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), matrix_tid: u32, indices: []const u32, w: anytype) !void {
    var cur_type: ?u32 = matrix_tid;
    for (indices) |index_id| {
        const def = getDef(module, index_id);
        const ti = if (cur_type) |t| getDef(module, t) else null;
        if (def != null and def.?.op == .Constant and def.?.words.len > 3) {
            const val = def.?.words[3];
            if (ti != null and ti.?.op == .TypeVector) {
                try w.writeAll(switch (val) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" });
                cur_type = ti.?.words[2];
            } else {
                try w.print("[{d}]", .{val});
                cur_type = if (ti != null and (ti.?.op == .TypeMatrix or ti.?.op == .TypeArray)) ti.?.words[2] else null;
            }
        } else {
            try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            cur_type = if (ti != null and (ti.?.op == .TypeMatrix or ti.?.op == .TypeArray)) ti.?.words[2] else null;
        }
    }
}

/// String-building variant of `writeMatrixTail` for `buildAccessExpr`.
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

fn writeAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name_raw = names.get(base_id) orelse "base";
    if (indices.len == 0) { try w.writeAll(base_name_raw); return; }

    // A cbuffer matrix is stored as the logical matrix M, but HLSL `m[i]`
    // selects a ROW where GLSL/SPIR-V selects a COLUMN — transpose the read.
    if (findUniformMatrixColumnAccess(module, names, base_id, indices)) |hit| {
        try w.writeAll("transpose(");
        try writeAccessExpr(module, names, base_id, indices[0 .. hit.boundary + 1], w);
        try w.writeAll(")");
        try writeMatrixTail(module, names, hit.matrix_tid, indices[hit.boundary + 1 ..], w);
        return;
    }
    // Mesh-output routing (set by spirvToHLSL): rewrite `<base>[idx]` →
    // `verts[idx].<member>` / `prims[idx]` / `prims_data[idx].<member>`.
    if (parseMeshRoute(base_name_raw)) |route| {
        try w.writeAll(route.base);
        // First index → array subscript (the per-vertex / per-primitive slot).
        const idx0 = indices[0];
        const idx0_inst = getDef(module, idx0);
        if (idx0_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                try w.print("[{d}]", .{def.words[3]});
            } else {
                try w.print("[{s}]", .{names.get(idx0) orelse "i"});
            }
        } else {
            try w.print("[{s}]", .{names.get(idx0) orelse "i"});
        }
        if (route.member) |m| try w.print(".{s}", .{m});
        // Walk any remaining indices (e.g. `verts[i].v_color[j]` for a
        // user `out vec4 v_color[][N]`) using simple constant/symbolic
        // formatting — the deeper type chain follows the element type.
        for (indices[1..]) |index_id| {
            const idx_inst = getDef(module, index_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    try w.print("[{d}]", .{def.words[3]});
                } else {
                    try w.print("[{s}]", .{names.get(index_id) orelse "i"});
                }
            } else {
                try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            }
        }
        return;
    }
    // Check if base is an SSBO (tagged with __ssbo_buf__ prefix)
    const is_ssbo = std.mem.startsWith(u8, base_name_raw, "__ssbo_buf__");
    const base_name = if (is_ssbo) base_name_raw["__ssbo_buf__".len..] else base_name_raw;
    const base_is_cb = isUniformVariable(module, base_id) and !is_ssbo;
    const cb_prefix = if (base_is_cb) base_name else "";

    // Runtime-array SSBO `{ T data[]; }` was flattened to RWStructuredBuffer<T>.
    // The access `b.data[i]` becomes `b[i]` — drop the struct-member index and
    // map the runtime-array index to the buffer index.
    const struct_type_id_opt = resolvePointeeType(module, base_id);
    const ssbo_elem_type: ?u32 = if (is_ssbo) blk: {
        const sid = struct_type_id_opt orelse break :blk null;
        break :blk ssboRuntimeArrayElement(module, sid);
    } else null;
    if (ssbo_elem_type != null and indices.len >= 1) {
        try w.writeAll(base_name);
        // indices[0] is the struct member index (always 0); drop it.
        // indices[1] (if present) is the buffer index; otherwise `b` alone.
        if (indices.len >= 2) {
            const idx_buf_id = indices[1];
            const idx_inst = getDef(module, idx_buf_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    try w.print("[{d}]", .{def.words[3]});
                } else {
                    try w.print("[{s}]", .{names.get(idx_buf_id) orelse "i"});
                }
            } else {
                try w.print("[{s}]", .{names.get(idx_buf_id) orelse "i"});
            }
        }
        // Walk remaining indices (into the element type) with the original logic.
        var cur_type: ?u32 = ssbo_elem_type;
        for (indices[@min(indices.len, 2)..]) |index_id| {
            const idx_inst = getDef(module, index_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    const val = def.words[3];
                    const is_vector = if (cur_type) |tid| blk: { const ti = getDef(module, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                    if (is_vector) {
                        try w.writeAll(switch (val) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" });
                    } else {
                        var used_name = false;
                        if (cur_type) |tid| {
                            const ti = getDef(module, tid);
                            if (ti) |tinst| {
                                if (tinst.op == .TypeStruct) {
                                    var mname_buf: [32]u8 = undefined;
                                    const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                    try w.print(".{s}", .{mname});
                                    used_name = true;
                                }
                            }
                        }
                        if (!used_name) try w.print("[{d}]", .{val});
                    }
                    if (cur_type) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                            else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                            else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                            else { cur_type = null; }
                        }
                    }
                } else {
                    try w.print("[{s}]", .{names.get(index_id) orelse "i"});
                    if (cur_type) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                            else { cur_type = null; }
                        }
                    }
                }
            } else {
                try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            }
        }
        return;
    }

    if (is_ssbo) try w.print("{s}[0]", .{base_name}) else if (!base_is_cb) try w.writeAll(base_name);
    var cur_type: ?u32 = struct_type_id_opt;
    var first_member = true;
    for (indices) |index_id| {
        const idx_inst = getDef(module, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(module, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try w.writeAll(switch (val) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" });
                } else if (base_is_cb and first_member) {
                    var mname_buf: [32]u8 = undefined;
                    var used_name = false;
                    if (cur_type) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                try w.print("{s}_{s}", .{cb_prefix, mname});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try w.print("{s}_m{d}", .{cb_prefix, val});
                    first_member = false;
                } else {
                    // Use member name for structs, [index] for arrays
                    var used_name = false;
                    if (cur_type) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                try w.print(".{s}", .{mname});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try w.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                        else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            } else {
                try w.print("[{s}]", .{names.get(index_id) orelse "i"});
                if (cur_type) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            }
        } else {
            try w.print("[{s}]", .{names.get(index_id) orelse "i"});
            if (cur_type) |tid| {
                const ti = getDef(module, tid);
                if (ti) |tinst| {
                    if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                    else { cur_type = null; }
                }
            }
        }
    }
}

fn resolvePointer(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, ptr_id) orelse {
        const name = names.get(ptr_id) orelse "var";
        return try alloc.dupe(u8, name);
    };
    if (inst.op == .AccessChain) {
        return try buildAccessExpr(module, names, inst.words[3], inst.words[4..], alloc);
    }
    const name = names.get(ptr_id) orelse "var";
    return try alloc.dupe(u8, name);
}

fn buildAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name_raw = names.get(base_id) orelse "base";

    if (indices.len == 0) return try alloc.dupe(u8, base_name_raw);

    // Transpose cbuffer matrix-column reads (see writeAccessExpr / the
    // findUniformMatrixColumnAccess doc-comment for why).
    if (findUniformMatrixColumnAccess(module, names, base_id, indices)) |hit| {
        var tbuf = std.ArrayList(u8).initCapacity(alloc, 64) catch return error.OutOfMemory;
        defer tbuf.deinit(alloc);
        try tbuf.appendSlice(alloc, "transpose(");
        const inner = try buildAccessExpr(module, names, base_id, indices[0 .. hit.boundary + 1], alloc);
        defer alloc.free(inner);
        try tbuf.appendSlice(alloc, inner);
        try tbuf.appendSlice(alloc, ")");
        try appendMatrixTail(module, names, hit.matrix_tid, indices[hit.boundary + 1 ..], &tbuf, alloc);
        return tbuf.toOwnedSlice(alloc);
    }

    // Mesh-output routing (set by spirvToHLSL): rewrite `<base>[idx]` →
    // `verts[idx].<member>` / `prims[idx]` / `prims_data[idx].<member>`.
    // Mirrors writeAccessExpr — see that function for rationale.
    if (parseMeshRoute(base_name_raw)) |route| {
        var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch return error.OutOfMemory;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, route.base);
        const idx0 = indices[0];
        const idx0_inst = getDef(module, idx0);
        if (idx0_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                try buf.print(alloc, "[{d}]", .{def.words[3]});
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(idx0) orelse "i"});
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(idx0) orelse "i"});
        }
        if (route.member) |m| try buf.print(alloc, ".{s}", .{m});
        for (indices[1..]) |index_id| {
            const idx_inst = getDef(module, index_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    try buf.print(alloc, "[{d}]", .{def.words[3]});
                } else {
                    try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            }
        }
        return buf.toOwnedSlice(alloc);
    }

    // Check if base is an SSBO (tagged with __ssbo_buf__ prefix)
    const is_ssbo = std.mem.startsWith(u8, base_name_raw, "__ssbo_buf__");
    const base_name = if (is_ssbo) base_name_raw["__ssbo_buf__".len..] else base_name_raw;

    // Check if base is a cbuffer/UBO variable (Uniform storage class)
    // In HLSL, cbuffer members are accessed using cbufferName_mN prefix
    const base_is_cbuffer = isUniformVariable(module, base_id) and !is_ssbo;
    const cbuffer_prefix = if (base_is_cbuffer) base_name else "";

    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);

    // Runtime-array SSBO `{ T data[]; }` was flattened to RWStructuredBuffer<T>.
    // The access `b.data[i]` becomes `b[i]` — drop the struct-member index and
    // map the runtime-array index to the buffer index.
    const pointee_type_id = resolvePointeeType(module, base_id);
    const ssbo_elem_type: ?u32 = if (is_ssbo) blk: {
        const sid = pointee_type_id orelse break :blk null;
        break :blk ssboRuntimeArrayElement(module, sid);
    } else null;
    if (ssbo_elem_type) |elem_type| {
        try buf.appendSlice(alloc, base_name);
        // indices[0] is the struct member index (always 0); drop it.
        if (indices.len >= 2) {
            const idx_buf_id = indices[1];
            const idx_inst = getDef(module, idx_buf_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    try buf.print(alloc, "[{d}]", .{def.words[3]});
                } else {
                    try buf.print(alloc, "[{s}]", .{names.get(idx_buf_id) orelse "i"});
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(idx_buf_id) orelse "i"});
            }
        }
        var cur: ?u32 = elem_type;
        for (indices[@min(indices.len, 2)..]) |index_id| {
            const idx_inst = getDef(module, index_id);
            if (idx_inst) |def| {
                if (def.op == .Constant and def.words.len > 3) {
                    const val = def.words[3];
                    const is_vector = if (cur) |tid| blk2: { const ti = getDef(module, tid); break :blk2 ti != null and ti.?.op == .TypeVector; } else false;
                    if (is_vector) {
                        try buf.appendSlice(alloc, switch (val) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" });
                    } else {
                        var used_name = false;
                        if (cur) |tid| {
                            const ti = getDef(module, tid);
                            if (ti) |tinst| {
                                if (tinst.op == .TypeStruct) {
                                    var mname_buf: [32]u8 = undefined;
                                    const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                    try buf.print(alloc, ".{s}", .{mname});
                                    used_name = true;
                                }
                            }
                        }
                        if (!used_name) try buf.print(alloc, "._m{d}", .{val});
                    }
                    if (cur) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeVector) { cur = tinst.words[2]; }
                            else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur = tinst.words[val + 2]; }
                            else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur = tinst.words[2]; }
                            else { cur = null; }
                        }
                    }
                } else {
                    try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
                    if (cur) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur = tinst.words[2]; }
                            else { cur = null; }
                        }
                    }
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            }
        }
        return buf.toOwnedSlice(alloc);
    }

    if (is_ssbo) {
        try buf.print(alloc, "{s}[0]", .{base_name});
    } else if (!base_is_cbuffer) {
        try buf.appendSlice(alloc, base_name);
    }

    // Walk the type chain starting from the base pointer's pointee type
    var current_type_id: ?u32 = pointee_type_id;
    var first_member = true; // Only use cbuffer prefix for the first member access

    for (indices) |index_id| {
        const idx_inst = getDef(module, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                // Check if current type is a vector (use swizzle) or struct (use _mN)
                const is_vector = if (current_type_id) |tid| blk: {
                    const ti = getDef(module, tid);
                    break :blk ti != null and ti.?.op == .TypeVector;
                } else false;

                if (is_vector) {
                    try buf.appendSlice(alloc, switch (val) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                } else if (base_is_cbuffer and first_member) {
                    // Cbuffer members use cbufferName_memberName prefix
                    var mname_buf: [32]u8 = undefined;
                    var used_name = false;
                    if (current_type_id) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                try buf.print(alloc, "{s}_{s}", .{ cbuffer_prefix, mname });
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try buf.print(alloc, "{s}_m{d}", .{ cbuffer_prefix, val });
                    first_member = false;
                } else {
                    // Use member name for structs, ._mN for arrays/vectors
                    var used_name = false;
                    if (current_type_id) |tid| {
                        const ti = getDef(module, tid);
                        if (ti) |tinst| {
                            if (tinst.op == .TypeStruct) {
                                var mname_buf: [32]u8 = undefined;
                                const mname = hlslGetMemberName(module, tid, val, &mname_buf);
                                try buf.print(alloc, ".{s}", .{mname});
                                used_name = true;
                            }
                        }
                    }
                    if (!used_name) try buf.print(alloc, "._m{d}", .{val});
                }

                // Advance type: struct member type, or vector element type
                if (current_type_id) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            current_type_id = tinst.words[2]; // element type
                        } else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) {
                            current_type_id = tinst.words[val + 2]; // member type
                        } else if (tinst.op == .TypeArray) {
                            current_type_id = tinst.words[2]; // element type
                        } else if (tinst.op == .TypeMatrix) {
                            current_type_id = tinst.words[2]; // column type
                        } else {
                            current_type_id = null;
                        }
                    }
                }
            } else {
                try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
                // Advance type for dynamic index (array element)
                if (current_type_id) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                            current_type_id = tinst.words[2];
                        } else {
                            current_type_id = null;
                        }
                    }
                }
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
            // Advance type for dynamic index
            if (current_type_id) |tid| {
                const ti = getDef(module, tid);
                if (ti) |tinst| {
                    if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                        current_type_id = tinst.words[2];
                    } else {
                        current_type_id = null;
                    }
                }
            }
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Check if an ID is a Uniform storage class variable (cbuffer/UBO).
fn isUniformVariable(module: *const ParsedModule, id: u32) bool {
    const inst = getDef(module, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        return sc == .Uniform or sc == .StorageBuffer;
    }
    return false;
}

/// If `struct_type_id` resolves to a TypeStruct whose only member is a
/// TypeRuntimeArray, return that runtime-array's element type id. Used to
/// flatten SSBOs shaped like `struct { T data[]; }` to a bare
/// `RWStructuredBuffer<T>` — HLSL has no unsized array members, so keeping
/// the struct wrapper collapses the runtime array to a scalar and DXC then
/// rejects any indexed access into it.
fn ssboRuntimeArrayElement(module: *const ParsedModule, struct_type_id: u32) ?u32 {
    const inst = getDef(module, struct_type_id) orelse return null;
    if (inst.op != .TypeStruct) return null;
    if (inst.words.len != 3) return null; // [header, struct_id, member0_type]
    const member_type_id = inst.words[2];
    const m = getDef(module, member_type_id) orelse return null;
    // A single-member SSBO whose member is an array `{ T data[]; }` or
    // `{ T data[N]; }` maps to `RWStructuredBuffer<T>` (the buffer IS the array),
    // matching spirv-cross. Both TypeRuntimeArray and TypeArray carry the element
    // type at words[2]. Without unwrapping the FIXED-size case, a large array
    // (e.g. `float4[1024]` = 16 KB) becomes one structured-buffer element, which
    // dxc rejects (">2048 bytes per element").
    if ((m.op != .TypeRuntimeArray and m.op != .TypeArray) or m.words.len < 3) return null;
    return m.words[2];
}

fn isSSBOVariable(module: *const ParsedModule, decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32) bool {
    const inst = getDef(module, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc == .Uniform or sc == .StorageBuffer) {
            // Check if the pointee type has BufferBlock decoration (SSBO)
            const ptr_type_inst = getDef(module, inst.words[1]);
            if (ptr_type_inst) |pti| {
                if (pti.op == .TypePointer and pti.words.len > 3) {
                    return hasDecoration(decorations, pti.words[3], .buffer_block);
                }
            }
        }
    }
    return false;
}

/// Resolve the pointee type of a pointer value (variable or AccessChain result).
/// Follows pointer types to get the inner type ID.
fn resolvePointeeType(module: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(module, id) orelse return null;
    switch (inst.op) {
        .Variable => {
            // Variable type is a pointer; get its pointee
            const ptr_type_inst = getDef(module, inst.words[1]) orelse return null;
            if (ptr_type_inst.op == .TypePointer and ptr_type_inst.words.len > 3) {
                return ptr_type_inst.words[3];
            }
            return null;
        },
        .AccessChain => {
            // Walk the base + indices to find the result type
            const base_type = resolvePointeeType(module, inst.words[3]);
            var cur: ?u32 = base_type;
            for (inst.words[4..]) |idx_id| {
                const idx_def = getDef(module, idx_id);
                if (cur) |tid| {
                    const ti = getDef(module, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur = tinst.words[2];
                        } else if (tinst.op == .TypeStruct) {
                            if (idx_def) |idx_def_res| {
                                if (idx_def_res.op == .Constant and idx_def_res.words.len > 3) {
                                    const val = idx_def_res.words[3];
                                    if (val + 2 < tinst.words.len) {
                                        cur = tinst.words[val + 2];
                                    } else cur = null;
                                }
                            }
                        } else if (tinst.op == .TypeArray) {
                            cur = tinst.words[2];
                        } else if (tinst.op == .TypeMatrix) {
                            cur = tinst.words[2];
                        } else {
                            cur = null;
                        }
                    }
                }
            }
            return cur;
        },
        else => return null,
    }
}

fn emitBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try hlslType(module, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s} {s} {s};\n", .{
        rt, names.get(inst.words[2]) orelse "v",
        names.get(inst.words[3]) orelse "a", op,
        names.get(inst.words[4]) orelse "b",
    });
}

fn emitCall(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try hlslType(module, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s}(", .{ rt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[3..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}

fn emitStd450(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, instruction: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const rt = try hlslType(module, inst.words[1], names, alloc);
    const func: spirv.GLSLstd450 = @enumFromInt(instruction);
    const hlsl_func: []const u8 = std450ToHlsl(func) orelse {
        try w.print("    // unhandled std450 #{d}\n", .{instruction});
        return;
    };

    try w.print("    {s} {s} = {s}(", .{ rt, names.get(inst.words[2]) orelse "v", hlsl_func });
    for (inst.words[5..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}

/// Classify an atomic pointer: SSBO variable or ImageTexelPointer (image atomic)
const HlslAtomicPtr = union(enum) {
    ssbo: []const u8,
    image: struct { img: []const u8, coord: []const u8 },
};

fn classifyHlslAtomicPtr(module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), ptr_id: u32) HlslAtomicPtr {
    const pd = getDef(module, ptr_id);
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

fn std450ToHlsl(func: spirv.GLSLstd450) ?[]const u8 {
    return switch (func) {
        .FAbs => "abs",
        .FSign => "sign",
        .Floor => "floor",
        .Ceil => "ceil",
        .Fract => "frac",
        .Sin => "sin",
        .Cos => "cos",
        .Tan => "tan",
        .Asin => "asin",
        .Acos => "acos",
        .Atan => "atan",
        .Atan2 => "atan2",
        .Pow => "pow",
        .Exp => "exp",
        .Log => "log",
        .Exp2 => "exp2",
        .Log2 => "log2",
        .Sqrt => "sqrt",
        .InverseSqrt => "rsqrt",
        .FMin => "min",
        .FMax => "max",
        .FClamp => "clamp",
        .FMix => "lerp",
        .Step => "step",
        .SmoothStep => "smoothstep",
        .Length => "length",
        .Distance => "distance",
        .Cross => "cross",
        .Normalize => "normalize",
        .Sinh => "sinh",
        .Cosh => "cosh",
        .Tanh => "tanh",
        .Asinh => "asinh",
        .Acosh => "acosh",
        .Atanh => "atanh",
        .InterpolateAtCentroid => "EvaluateAttributeAtCentroid",
        .InterpolateAtSample => "EvaluateAttributeAtSample",
        .InterpolateAtOffset => "EvaluateAttributeSnapped",
        .Reflect => "reflect",
        .Refract => "refract",
        .FaceForward => "faceforward",
        .Determinant => "determinant",
        .MatrixInverse => "inverse",
        else => blk: {
            // Fallback for GLSL.std.450 opcodes not matched in the named-switch arm above
            // (the integer min/max/clamp variants, and the lower-numbered builtins).
            const val = @intFromEnum(func);
            break :blk switch (val) {
                // Correct GLSLstd450 instruction IDs (per SPIR-V spec)
                1 => "round",
                2 => "round", // RoundEven — HLSL round() rounds to even
                3 => "trunc",
                4 => "abs",
                5 => "abs",        // SAbs
                6 => "sign",
                7 => "sign",       // SSign (sign for signed ints)
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
                25 => "atan2",
                26 => "pow",
                19 => "sinh",
                20 => "cosh",
                21 => "tanh",
                22 => "asinh",
                23 => "acosh",
                24 => "atanh",
                27 => "exp",
                28 => "log",
                29 => "exp2",
                30 => "log2",
                31 => "sqrt",
                32 => "rsqrt",     // InverseSqrt
                33 => "determinant",
                34 => "mul",       // matrixCompMult - component-wise multiply
                35 => "modf",      // Modf (scalar return, pointer out-param)
                36 => "modf",       // ModfStruct (struct return)
                37 => "min",       // FMin
                38 => "min",       // UMin
                39 => "min",       // SMin
                40 => "max",       // FMax
                41 => "max",       // UMax
                42 => "max",       // SMax
                43 => "clamp",     // FClamp
                44 => "clamp",     // UClamp
                45 => "clamp",     // SClamp
                46 => "lerp",      // FMix / mix
                48 => "step",
                49 => "smoothstep",
                50 => "mad",       // FMA (fused multiply-add) — HLSL uses mad for float
                51 => "frexp",     // Frexp (scalar return, pointer out-param)
                52 => "frexp",     // FrexpStruct (struct return - intercepted)
                53 => "ldexp",     // Ldexp
                66 => "length",    // Length
                67 => "distance",  // Distance
                68 => "cross",     // Cross
                69 => "normalize", // Normalize
                70 => "faceforward", // FaceForward (HLSL intrinsic)
                71 => "reflect",   // Reflect
                72 => "refract",   // Refract
                73 => "firstbitlow", // FindILsb → HLSL firstbitlow
                74 => "firstbithigh", // FindSMsb → HLSL firstbithigh
                75 => "firstbithigh", // FindUMsb → HLSL firstbithigh
                79 => "min", 80 => "max", 81 => "clamp",
                54 => "pack_snorm4x8", 55 => "pack_unorm4x8",
                56 => "pack_snorm2x16", 57 => "pack_unorm2x16", 58 => "pack_half2x16",
                60 => "unpack_snorm2x16", 61 => "unpack_unorm2x16", 62 => "unpack_half2x16",
                63 => "unpack_snorm4x8", 64 => "unpack_unorm4x8",
                76 => "EvaluateAttributeAtCentroid", 77 => "EvaluateAttributeAtSample", 78 => "EvaluateAttributeSnapped",
                else => null,
            };
        },
    };
}

/// Resolve an ID to an HLSL expression string. Falls back to constant literal for unnamed IDs.
fn idToExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), id: u32, alloc: std.mem.Allocator) []const u8 {
    if (names.get(id)) |name| return name;
    const def = getDef(module, id) orelse return "0";
    if (def.op == .Constant and def.words.len > 3) {
        const val = def.words[3];
        return std.fmt.allocPrint(alloc, "{d}", .{val}) catch "0";
    }
    if (def.op == .ConstantTrue) return "true";
    if (def.op == .ConstantFalse) return "false";
    return "0";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------


