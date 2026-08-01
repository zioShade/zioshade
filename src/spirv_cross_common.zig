// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared SPIR-V cross-compiler infrastructure.
//!
//! This module provides the SPIR-V binary parser, type/annotation resolution,
//! and helper utilities used by all cross-compilation backends (HLSL, GLSL, MSL).

const std = @import("std");
const compat = @import("compat.zig");
const spirv = @import("spirv.zig");

// ---------------------------------------------------------------------------
// SPIR-V Binary Parser
// ---------------------------------------------------------------------------

pub const Instruction = struct {
    op: spirv.Op,
    words: []const u32,
};

pub const MeshTopology = enum { triangles, lines, points };

pub const ParsedModule = struct {
    instructions: []const Instruction,
    id_defs: []const ?usize,
    entry_point_id: ?u32 = null,
    execution_model: spirv.ExecutionModel = .Fragment,
    local_size: [3]u32 = [3]u32{ 1, 1, 1 },
    mesh_topology: ?MeshTopology = null,
    mesh_max_vertices: ?u32 = null,
    mesh_max_primitives: ?u32 = null,

    pub fn deinit(self: *ParsedModule, alloc: std.mem.Allocator) void {
        if (self.instructions.len > 0) {
            const bytes = @constCast(self.instructions.ptr);
            alloc.free(bytes[0..self.instructions.len]);
        }
        alloc.free(@constCast(self.id_defs.ptr)[0..self.id_defs.len]);
    }
};

pub fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;

    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch
        return error.OutOfMemory;
    errdefer instructions.deinit(alloc);

    // `words[3]` is the id bound; `id_defs` is sized to it. A hostile module can
    // set an absurd bound (e.g. 0xFFFFFFFF) that would make this allocation and
    // its @memset touch tens of gigabytes and hang. Every result id is defined by
    // at least a two-word instruction, so a legitimate module's bound never
    // exceeds its word count. Reject anything larger as malformed.
    const bound = if (words.len > 3) words[3] else 0;
    if (bound > words.len) return error.InvalidSpirv;
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
            // #475: LocalSizeId (spec-constant workgroup size) — operands are the
            // RESULT IDs of OpSpecConstant integers, not literals. Resolve each to its
            // default value (OpSpecConstant layout: [op, type, result, value...]) so
            // the backends emit the specialized (default) @workgroup_size / [numthreads] /
            // local_size. Without this, module.local_size stayed (1,1,1) and the shader
            // dispatched a 1x1x1 workgroup instead of the intended size (silent-wrong).
            if (mode == .LocalSizeId and inst.words.len >= 6) {
                module.local_size = .{
                    specConstantDefault(&module, inst.words[3], 1),
                    specConstantDefault(&module, inst.words[4], 1),
                    specConstantDefault(&module, inst.words[5], 1),
                };
            }
            // Mesh shader execution modes
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
        // OpExecutionModeId (331): the id-operand form. LocalSizeId here carries
        // spec-constant RESULT IDs (the valid form -- OpExecutionMode cannot take id
        // operands, so the LocalSizeId arm above only ever fires on invalid input).
        // Resolve each to its default (specConstantDefault now also evaluates
        // OpSpecConstantOp, e.g. SC*2) so the backends emit the intended workgroup
        // size instead of silently dispatching 1x1x1.
        if (inst.op == .ExecutionModeId and inst.words.len >= 6) {
            const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]);
            if (mode == .LocalSizeId) {
                module.local_size = .{
                    specConstantDefault(&module, inst.words[3], 1),
                    specConstantDefault(&module, inst.words[4], 1),
                    specConstantDefault(&module, inst.words[5], 1),
                };
            }
        }
    }

    return module;
}

/// Find the function ID for a named entry point. Returns null if not found.
pub fn findEntryPoint(module: *const ParsedModule, name: []const u8) ?u32 {
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 3) {
            // words: header, execution_model, func_id, name_string...
            const ep_name = extractString(inst.words[3..]);
            if (std.mem.eql(u8, ep_name, name)) {
                return inst.words[2];
            }
        }
    }
    return null;
}

/// Extract a null-terminated string from SPIR-V literal words.
fn extractString(words: []const u32) []const u8 {
    const bytes = std.mem.sliceAsBytes(words);
    var len: usize = 0;
    while (len < bytes.len) : (len += 1) {
        if (bytes[len] == 0) break;
    }
    return bytes[0..len];
}

pub fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch (op) {
        .TypeVoid,
        .TypeBool,
        .TypeInt,
        .TypeFloat,
        .TypeVector,
        .TypeMatrix,
        .TypeImage,
        .TypeSampler,
        .TypeSampledImage,
        .TypeArray,
        .TypeRuntimeArray,
        .TypeStruct,
        .TypePointer,
        .TypeFunction,
        .TypeForwardPointer,
        .TypeAccelerationStructureKHR,
        .TypeRayQueryKHR,
        .TypeTensorARM,
        => if (words.len > 1) words[1] else null,

        .ConstantTrue,
        .ConstantFalse,
        .Constant,
        .ConstantComposite,
        .ConstantNull,
        .SpecConstant,
        .SpecConstantTrue,
        .SpecConstantFalse,
        .SpecConstantComposite,
        .SpecConstantOp,
        .Undef,
        => if (words.len > 2) words[2] else null,

        .Variable,
        .Function,
        .FunctionParameter,
        => if (words.len > 2) words[2] else null,

        .Load,
        .AccessChain,
        .CompositeConstruct,
        .CompositeExtract,
        .CompositeInsert,
        .VectorShuffle,
        .SampledImage,
        .ImageSampleImplicitLod,
        .ImageSampleExplicitLod,
        .ImageFetch,
        .ImageGather,
        .ImageQuerySizeLod,
        .ImageQuerySize,
        .ImageTexelPointer,
        .FunctionCall,
        .CopyObject,
        .Phi,
        .ConvertFToS,
        .ConvertSToF,
        .ConvertUToF,
        .ConvertFToU,
        .UConvert,
        .SConvert,
        .FConvert,
        .Bitcast,
        .QuantizeToF16,
        .SNegate,
        .FNegate,
        .IAdd,
        .FAdd,
        .ISub,
        .FSub,
        .IMul,
        .FMul,
        .UDiv,
        .SDiv,
        .FDiv,
        .UMod,
        .SRem,
        .SMod,
        .FRem,
        .FMod,
        .VectorTimesScalar,
        .MatrixTimesScalar,
        .VectorTimesMatrix,
        .MatrixTimesVector,
        .MatrixTimesMatrix,
        .Dot,
        .Transpose,
        .OuterProduct,
        .Select,
        .LogicalOr,
        .LogicalAnd,
        .LogicalNot,
        .LogicalEqual,
        .LogicalNotEqual,
        .IEqual,
        .INotEqual,
        .UGreaterThan,
        .SGreaterThan,
        .UGreaterThanEqual,
        .SGreaterThanEqual,
        .ULessThan,
        .SLessThan,
        .ULessThanEqual,
        .SLessThanEqual,
        .FOrdEqual,
        .FOrdNotEqual,
        .FUnordNotEqual,
        .FOrdLessThan,
        .FOrdGreaterThan,
        .FOrdLessThanEqual,
        .FOrdGreaterThanEqual,
        // Unordered float inequalities produce a bool result id like their ordered
        // siblings. Without this the parser never records their result in id_defs,
        // so a non-inlined use (e.g. the scalar-bool splat into vecN<bool> for an
        // OpSelect condition, or an OpStore) can't resolve the name and falls back
        // to a bare "0". The WGSL backend lowers them to `!(ordered complement)`. (#170)
        .FUnordLessThan,
        .FUnordGreaterThan,
        .FUnordLessThanEqual,
        .FUnordGreaterThanEqual,
        // OpFUnordEqual too (WGSL lowers it to a nested select composing the
        // (a==b)||isNaN(a)||isNaN(b) definition; same id-registration need). (#170)
        .FUnordEqual,
        .ShiftRightLogical,
        .ShiftRightArithmetic,
        .ShiftLeftLogical,
        .BitwiseOr,
        .BitwiseXor,
        .BitwiseAnd,
        .Not,
        .IsNan,
        .IsInf,
        .All,
        .Any,
        .DPdx,
        .DPdy,
        .Fwidth,
        .DPdxFine,
        .DPdyFine,
        .FwidthFine,
        .DPdxCoarse,
        .DPdyCoarse,
        .FwidthCoarse,
        .VectorExtractDynamic,
        .ExtInst,
        .OpImage,
        .AtomicIAdd,
        .AtomicISub,
        .AtomicExchange,
        .AtomicSMin,
        .AtomicUMin,
        .AtomicSMax,
        .AtomicUMax,
        .AtomicAnd,
        .AtomicOr,
        .AtomicXor,
        .ImageSampleDrefImplicitLod,
        .ImageSampleDrefExplicitLod,
        .ImageSampleProjImplicitLod,
        .ImageSampleProjExplicitLod,
        .ImageSampleProjDrefImplicitLod,
        .ImageSampleProjDrefExplicitLod,
        .ImageDrefGather,
        .ImageQueryLod,
        .ImageQueryLevels,
        .ImageQuerySamples,
        .ImageRead,
        .AtomicCompareExchange,
        .AtomicFAddEXT,
        .ArrayLength,
        .BitReverse,
        .BitCount,
        .BitFieldInsert,
        .BitFieldSExtract,
        .BitFieldUExtract,
        .GroupNonUniformElect,
        .GroupNonUniformAll,
        .GroupNonUniformAny,
        .GroupNonUniformAllEqual,
        .GroupNonUniformBroadcast,
        .GroupNonUniformBroadcastFirst,
        .GroupNonUniformBallot,
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
        .GroupNonUniformLogicalAnd,
        .GroupNonUniformLogicalOr,
        .GroupNonUniformShuffle,
        .GroupNonUniformShuffleXor,
        .GroupNonUniformShuffleUp,
        .GroupNonUniformShuffleDown,
        .SubgroupAllKHR,
        .SubgroupAnyKHR,
        => if (words.len > 2) words[2] else null,

        else => blk: {
            // OpIAddCarry (149) / OpISubBorrow (150): `spirv.Op` is non-exhaustive and
            // does NOT name these, but each DOES define a result id (result-type word
            // [1], result word[2]). Index it by raw opcode number so getDef/collectNames
            // can resolve the {result, carry|borrow} struct that the WGSL backend lowers
            // via OpCompositeExtract. (#170)
            const opc = @intFromEnum(op);
            if (opc == 149 or opc == 150) break :blk if (words.len > 2) words[2] else null;
            break :blk null;
        },
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Detects a 64-bit numeric type (OpTypeFloat/OpTypeInt with Width=64) anywhere in the
/// module. 32-bit targets (GLSL/HLSL/MSL/WGSL) cannot represent these; a 64-bit constant
/// silently truncates/misreads, so each backend honest-errors up front (mirrors WGSL). (#476)
pub const Wide64Type = enum { none, float64, int64 };
pub fn wide64Type(instructions: anytype) Wide64Type {
    for (instructions) |inst| {
        if (inst.words.len > 2 and inst.words[2] == 64) {
            if (inst.op == .TypeFloat) return .float64;
            if (inst.op == .TypeInt) return .int64;
        }
    }
    return .none;
}

pub fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    const idx = if (id < module.id_defs.len) module.id_defs[id] orelse return null else return null;
    if (idx >= module.instructions.len) return null;
    return module.instructions[idx];
}

/// The default value of an integer OpSpecConstant `id` (its literal word[3]), used to
/// resolve LocalSizeId operands to concrete workgroup dimensions. Falls back to
/// `fallback` if `id` is not an OpSpecConstant (shouldn't happen for valid SPIR-V).
/// (#475)
pub fn specConstantDefault(module: *const ParsedModule, id: u32, fallback: u32) u32 {
    return specConstantDefaultRec(module, id, fallback, 0);
}

/// Resolve the default value of a specialization constant id, evaluating an
/// `OpSpecConstantOp` (e.g. `SC * 2` for a workgroup size) to its concrete default
/// by recursively resolving operands and applying the op. Previously only plain
/// `OpSpecConstant` was handled, so an `OpSpecConstantOp` fell back to `fallback`
/// (e.g. a LocalSizeId workgroup size silently became 1x1x1 -- a silent miscompile).
/// `depth` guards against a malformed cyclic OpSpecConstantOp chain (valid SPIR-V is
/// acyclic, so this is defensive); the DAG depth is bounded so recursion terminates.
fn specConstantDefaultRec(module: *const ParsedModule, id: u32, fallback: u32, depth: u32) u32 {
    if (depth > 32) return fallback;
    const def = getDef(module, id) orelse return fallback;
    if ((def.op == .SpecConstant or def.op == .Constant) and def.words.len > 3) return def.words[3];
    if (def.op != .SpecConstantOp or def.words.len <= 4) return fallback;
    // OpSpecConstantOp layout: [type, result, opcode, operand-ids...].
    const op: spirv.Op = @enumFromInt(def.words[3]);
    const ops = def.words[4..];
    const a = specConstantDefaultRec(module, ops[0], fallback, depth + 1);
    const b = if (ops.len > 1) specConstantDefaultRec(module, ops[1], fallback, depth + 1) else 0;
    const si_a: i32 = @bitCast(a);
    const si_b: i32 = @bitCast(b);
    const int_min_neg_one = (si_a == std.math.minInt(i32) and si_b == -1);
    return switch (op) {
        .Not => ~a,
        .SNegate => @bitCast(-%si_a),
        // Width conversion; for a workgroup dim (positive) the value is unchanged.
        .UConvert, .SConvert => a,
        .IAdd => a +% b,
        .ISub => a -% b,
        .IMul => a *% b,
        .UDiv => if (b == 0) fallback else a / b,
        .SDiv => if (b == 0 or int_min_neg_one) fallback else @bitCast(@divTrunc(si_a, si_b)),
        .UMod => if (b == 0) fallback else a % b,
        .SRem => if (b == 0 or int_min_neg_one) fallback else @bitCast(@rem(si_a, si_b)),
        .SMod => if (b == 0 or int_min_neg_one) fallback else @bitCast(@mod(si_a, si_b)),
        .ShiftLeftLogical => a << @intCast(b & 31),
        .ShiftRightLogical => a >> @intCast(b & 31),
        .ShiftRightArithmetic => @bitCast(si_a >> @intCast(b & 31)),
        .BitwiseOr => a | b,
        .BitwiseXor => a ^ b,
        .BitwiseAnd => a & b,
        // Opcodes not evaluated here (vector/comparison -- atypical for a workgroup-dim
        // expression) fall back; a wrong default is safer than a guess.
        else => fallback,
    };
}

/// True if a struct type carries `Block` or `BufferBlock` — a UBO/SSBO interface
/// block (this also covers builtin blocks like gl_PerVertex, which are Block-
/// decorated). Such structs are emitted by each backend's cbuffer/SSBO path, not
/// as plain value structs. `module` is `anytype` because the HLSL backend uses a
/// distinct ParsedModule struct; all three share the `.instructions` shape.
pub fn structIsInterfaceBlock(module: anytype, struct_id: u32) bool {
    for (module.instructions) |inst| {
        if (inst.op == .Decorate and inst.words.len >= 3 and inst.words[1] == struct_id) {
            const dec: spirv.Decoration = @enumFromInt(inst.words[2]);
            if (dec == .block or dec == .buffer_block) return true;
        }
    }
    return false;
}

/// If `inst` is a value-producing op whose result type is (or is an array of) a
/// plain (non-interface-block) struct, return that struct type id; else null.
/// Used by every text backend to declare struct types that appear ONLY as SSA
/// values: when a function taking/returning a struct is inlined, its struct
/// locals become OpCompositeConstruct/OpFunctionCall results rather than
/// OpVariables, so an OpVariable-only scan misses them and the type is used
/// (`Light l = Light(...)`) but never declared. `module`/`inst` are `anytype`
/// (the HLSL backend has its own ParsedModule/Instruction types).
pub fn structValueTypeId(module: anytype, inst: anytype) ?u32 {
    switch (inst.op) {
        .CompositeConstruct, .CompositeExtract, .CompositeInsert, .Load, .FunctionCall, .CopyObject, .Phi, .Select, .ConstantComposite => {},
        else => return null,
    }
    if (inst.words.len < 3) return null;
    var sid = inst.words[1]; // result type id
    var si = localGetDef(module.instructions, module.id_defs, sid) orelse return null;
    while ((si.op == .TypeArray or si.op == .TypeRuntimeArray) and si.words.len > 2) {
        sid = si.words[2];
        si = localGetDef(module.instructions, module.id_defs, sid) orelse return null;
    }
    if (si.op != .TypeStruct) return null;
    if (structIsInterfaceBlock(module, sid)) return null;
    return sid;
}

/// #414: whether a function parameter can carry a result back to its caller.
/// In logical SPIR-V that is possible ONLY for a pointer parameter (the GLSL
/// out/inout lowering, as the frontend emits it). A by-value parameter is a
/// read-only copy: promoting it to out / inout / thread& in a text backend is
/// always wrong. In particular, a `Variable + Store(param)` function prologue
/// is NOT evidence of an out param; it is just GLSL's by-value copy of an `in`
/// param into a mutable local (`float d = p;`).
pub fn paramIsPointer(instructions: anytype, id_defs: anytype, param_id: u32) bool {
    const p = localGetDef(instructions, id_defs, param_id) orelse return false;
    if (p.op != .FunctionParameter or p.words.len < 3) return false;
    const t = localGetDef(instructions, id_defs, p.words[1]) orelse return false;
    return t.op == .TypePointer;
}

/// True if `func_id`'s parameter at position `param_idx` is a pointer param.
pub fn functionParamIsPointer(instructions: anytype, id_defs: anytype, func_id: u32, param_idx: usize) bool {
    const f = localGetDef(instructions, id_defs, func_id) orelse return false;
    if (f.op != .Function) return false;
    const fidx = if (func_id < id_defs.len) id_defs[func_id] orelse return false else return false;
    var i: usize = fidx + 1;
    var pi: usize = 0;
    while (i < instructions.len) : (i += 1) {
        const inst = instructions[i];
        if (inst.op == .FunctionParameter and inst.words.len > 2) {
            if (pi == param_idx) return paramIsPointer(instructions, id_defs, inst.words[2]);
            pi += 1;
        } else if (inst.op != .Label) break;
    }
    return false;
}

pub const PtrParamDir = enum { out_only, in_out };

/// Classify a POINTER function parameter (only call when the param is a pointer) as
/// `out` (written, never read) or `inout` (read, or read+write) from the callee
/// body. The frontend emits a Function-storage pointer param only for genuine
/// out/inout, so a pointer param always needs one of these qualifiers; the choice
/// affects correctness (an `out` param drops the caller's incoming value, so a
/// param that is READ must be `inout`). Biased to `inout`: it is the safe superset,
/// and `out` is returned only when the body provably writes without reading.
pub fn classifyPointerParam(instructions: anytype, id_defs: anytype, alloc: std.mem.Allocator, func_id: u32, param_idx: usize) PtrParamDir {
    const fidx = if (func_id < id_defs.len) id_defs[func_id] orelse return .in_out else return .in_out;
    // Resolve the param id at param_idx.
    var i: usize = fidx + 1;
    var pi: usize = 0;
    var param_id: u32 = 0;
    var found = false;
    while (i < instructions.len) : (i += 1) {
        const inst = instructions[i];
        if (inst.op == .FunctionParameter and inst.words.len > 2) {
            if (pi == param_idx) {
                param_id = inst.words[2];
                found = true;
                break;
            }
            pi += 1;
        } else if (inst.op != .Label) break;
    }
    if (!found) return .in_out;

    // Alias set: the param and every pointer transitively derived from it
    // (OpAccessChain / OpCopyObject). SSA/dominance order means one forward pass
    // over the body suffices.
    var set = std.AutoHashMap(u32, void).init(alloc);
    defer set.deinit();
    set.put(param_id, {}) catch return .in_out;
    var read = false;
    var written = false;
    var j = fidx + 1;
    while (j < instructions.len) : (j += 1) {
        const inst = instructions[j];
        if (inst.op == .FunctionEnd) break;
        switch (inst.op) {
            .AccessChain, .CopyObject => {
                if (inst.words.len > 3 and set.contains(inst.words[3])) set.put(inst.words[2], {}) catch {};
            },
            .Load => {
                if (inst.words.len > 3 and set.contains(inst.words[3])) read = true;
            },
            .Store => {
                if (inst.words.len > 2 and set.contains(inst.words[1])) written = true;
            },
            .FunctionCall => {
                // Passing the pointer onward can read it — force inout.
                if (inst.words.len > 4) {
                    for (inst.words[4..]) |a| {
                        if (set.contains(a)) {
                            read = true;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }
    return if (written and !read) .out_only else .in_out;
}

/// Detect out-parameters by scanning function calls in the entry function:
/// records (called function id -> param positions) for every call argument
/// that is a stage Output variable, i.e. the frontend passed the out/inout
/// destination by pointer (`mainImage(_fragColor, ...)`). #414: only positions
/// whose callee parameter is itself a POINTER are recorded; a by-value
/// parameter is a read-only copy and can never write back to the caller, so
/// marking it `out` corrupts the call (the argument value never arrives).
/// Shared by the HLSL, GLSL and MSL backends (previously triplicated).
pub fn detectOutParams(
    instructions: anytype,
    id_defs: anytype,
    entry_id: u32,
    out_param_info: *std.AutoHashMap(u32, std.ArrayList(usize)),
    alloc: std.mem.Allocator,
) void {
    const func_idx = if (entry_id < id_defs.len) id_defs[entry_id] orelse return else return;

    // Collect all Output storage class variable IDs.
    var output_vars = std.AutoHashMap(u32, void).init(alloc);
    defer output_vars.deinit();
    for (instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output) output_vars.put(inst.words[2], {}) catch {};
        }
    }

    // Scan entry function body for FunctionCall instructions.
    var idx = func_idx + 1;
    while (idx < instructions.len) : (idx += 1) {
        const inst = instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op != .FunctionCall or inst.words.len < 4) continue;
        const called_func_id = inst.words[3];
        for (inst.words[4..], 0..) |arg_id, param_idx| {
            if (!output_vars.contains(arg_id)) continue;
            if (!functionParamIsPointer(instructions, id_defs, called_func_id, param_idx)) continue;
            const gop = out_param_info.getOrPut(called_func_id) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(usize).initCapacity(alloc, 4) catch continue;
            }
            gop.value_ptr.append(alloc, param_idx) catch {};
        }
    }
}

/// True if the module declares an opaque (sampler / texture / sampled-image) array
/// resource — a GLSL `sampler2D tex[N]` / `tex[]` descriptor array. `include_runtime`
/// also matches the UNBOUNDED form (`OpTypeRuntimeArray`, from `tex[]` /
/// GL_EXT_nonuniform_qualifier); pass it for backends with no array-of-opaque support
/// AT ALL (WGSL core: no binding_array). MSL passes false to preserve its existing
/// runtime-array handling. The bounded `OpTypeArray` form is always matched.
pub fn hasOpaqueArrayResource(module: *const ParsedModule, include_runtime: bool) bool {
    return hasOpaqueArrayResourceSlices(module.instructions, module.id_defs, include_runtime);
}

/// Slice-based variant of `hasOpaqueArrayResource` — takes the raw instruction /
/// id_defs slices via `anytype` so it works across the distinct per-backend
/// `ParsedModule` types (the HLSL backend keeps its own). Single source of truth
/// for the multi-level array unwrap; `hasOpaqueArrayResource` delegates here.
pub fn hasOpaqueArrayResourceSlices(instructions: anytype, id_defs: anytype, include_runtime: bool) bool {
    for (instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .UniformConstant) continue;
        const ptr = localGetDef(instructions, id_defs, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        const pe = localGetDef(instructions, id_defs, ptr.words[3]) orelse continue;
        const is_array = pe.op == .TypeArray or (include_runtime and pe.op == .TypeRuntimeArray);
        if (!is_array or pe.words.len < 3) continue;
        // OpTypeArray and OpTypeRuntimeArray both carry the element type in words[2].
        // Unwrap EVERY array level: a NESTED resource array (e.g. `sampler1D s[2][2]`
        // = array-of-array-of-sampledimage) must be detected too, not just one level.
        var el = localGetDef(instructions, id_defs, pe.words[2]) orelse continue;
        while ((el.op == .TypeArray or el.op == .TypeRuntimeArray) and el.words.len >= 3) {
            // localGetDef null = broken/incomplete SPIR-V; `el` stays a TypeArray so
            // the opaque check below returns false safely (no false positive).
            el = localGetDef(instructions, id_defs, el.words[2]) orelse break;
        }
        if (el.op == .TypeSampledImage or el.op == .TypeSampler or el.op == .TypeImage) return true;
    }
    return false;
}

/// True if `var_id` is ever written — directly (`OpStore %var ...`) or through
/// a single-level access chain rooted at it
/// (`%c = OpAccessChain %p %var ...; OpStore %c`). Used to keep the
/// const-initializer aliasing below from touching a mutable global. Detects only
/// direct + one-level-chain stores (and not pass-by-pointer to a storing
/// callee); sufficient because zioshade never emits either for a `const` global —
/// a const global is never written at all. Arbitrary ingested SPIR-V with a
/// mutated const-initialised Private global via a deeper chain is the only blind
/// spot.
fn privateVarMutated(module: *const ParsedModule, var_id: u32) bool {
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

/// Design A backend support — a module-scope `const T arr[N] = …` global lowers
/// to a Private `OpVariable` carrying a constant initializer
/// (`%var = OpVariable %ptr Private %init`); the variable is never stored to.
/// Backends emit the initializer constant as a promoted global const (e.g.
/// `const float v4[16] = {…}`) but don't initialise the Private variable, so an
/// access `arr[i]` reads uninitialised memory (silent-wrong). Alias the
/// variable's name to its initializer constant's name so every access resolves
/// to the constant; the (now-redundant) variable declaration is skipped by each
/// backend's "is this id a const-initialised private var?" check
/// (`constInitializedPrivateVar`). Only fires for a constant initializer on a
/// never-written Private variable, so ingested mutable globals are untouched.
pub fn aliasConstInitializedPrivateVars(
    alloc: std.mem.Allocator,
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
) void {
    for (module.instructions) |inst| {
        const init_id = constInitializedPrivateVar(module, inst) orelse continue;
        const var_id = inst.words[2];
        const init_name = names.get(init_id) orelse continue;
        const dup = alloc.dupe(u8, init_name) catch continue;
        if (names.fetchPut(var_id, dup) catch null) |old| alloc.free(old.value);
    }
}

/// If `inst` is a Private `OpVariable` with a *constant* initializer operand and
/// is never written, return the initializer constant's id; else null. Backends
/// use this to (a) skip declaring the variable and (b) confirm an access base is
/// a promoted const. Returns null for anything else.
pub fn constInitializedPrivateVar(module: *const ParsedModule, inst: Instruction) ?u32 {
    if (inst.op != .Variable or inst.words.len < 5) return null; // needs initializer operand
    const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
    if (sc != .Private) return null;
    const init_id = inst.words[4];
    const init_def = getDef(module, init_id) orelse return null;
    switch (init_def.op) {
        .Constant, .ConstantComposite, .ConstantTrue, .ConstantFalse => {},
        else => return null,
    }
    if (privateVarMutated(module, inst.words[2])) return null;
    return init_id;
}

pub fn getTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(module, id) orelse return null;
    return switch (inst.op) {
        .TypeVoid,
        .TypeBool,
        .TypeInt,
        .TypeFloat,
        .TypeVector,
        .TypeMatrix,
        .TypeImage,
        .TypeSampler,
        .TypeSampledImage,
        .TypeArray,
        .TypeRuntimeArray,
        .TypeStruct,
        .TypePointer,
        .TypeFunction,
        => null,
        else => if (inst.words.len > 1) inst.words[1] else null,
    };
}

pub fn resolvePointeeType(module: *const ParsedModule, id: u32) ?u32 {
    const ptr_inst = getDef(module, id) orelse return null;
    if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) return ptr_inst.words[3];
    return null;
}

// ---------------------------------------------------------------------------
// Decoration Types
// ---------------------------------------------------------------------------

pub const DecorationEntry = struct {
    decoration: spirv.Decoration,
    extra: []const u32,
};

pub fn collectDecorations(alloc: std.mem.Allocator, module: *const ParsedModule, decorations: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
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

pub fn getDecorationValue(decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decorations.get(id) orelse return null;
    for (list.items) |entry| {
        if (entry.decoration == dec and entry.extra.len > 0) return entry.extra[0];
    }
    return null;
}

// ---------------------------------------------------------------------------
// Name Resolution
// ---------------------------------------------------------------------------

pub fn collectNames(alloc: std.mem.Allocator, module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    for (module.instructions) |inst| {
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

        if (inst.op == .Constant and inst.words.len > 3) {
            const rid = inst.words[2];
            const type_id = inst.words[1];
            const type_inst = getDef(module, type_id);
            if (type_inst) |ti| {
                const literal = constantLiteral(alloc, ti, inst.words[3..]) catch continue;
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
        if (inst.op == .ConstantComposite and inst.words.len > 3) {
            const rid = inst.words[2];
            const type_id = inst.words[1];
            const type_inst = getDef(module, type_id);
            if (type_inst) |ti| {
                if (ti.op == .TypeVector) {
                    const scalar_raw = tryResolveTypeName(module, ti.words[2]);
                    const count = ti.words[3];
                    // This composite-constant naming is consumed ONLY by the WGSL
                    // backend, so the constructor must use WGSL syntax. tryResolve-
                    // TypeName returns the GLSL scalar spelling; emit the WGSL
                    // vector form `vec{N}<wgsl_scalar>(...)`. Previously this used
                    // the GLSL spelling `{scalar}{N}(` (e.g. `uint2(`), which naga
                    // rejects (leaks as an undefined identifier).
                    const wgsl_scalar: []const u8 = if (std.mem.eql(u8, scalar_raw, "float")) "f32" else if (std.mem.eql(u8, scalar_raw, "int")) "i32" else if (std.mem.eql(u8, scalar_raw, "uint")) "u32" else scalar_raw;
                    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                    defer buf.deinit(alloc);
                    compat.listWriter(&buf, alloc).print("vec{d}<{s}>(", .{ count, wgsl_scalar }) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) compat.listWriter(&buf, alloc).writeAll(", ") catch continue;
                        const bc = wgslNonFiniteBitcast(alloc, module, comp_id);
                        defer if (bc) |s| alloc.free(s);
                        const comp_name = bc orelse (names.get(comp_id) orelse "0.0");
                        compat.listWriter(&buf, alloc).writeAll(comp_name) catch continue;
                    }
                    compat.listWriter(&buf, alloc).writeAll(")") catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                } else if (ti.op == .TypeStruct) {
                    // Struct constant: emit as StructName(field1, field2, ...)
                    const struct_name = names.get(type_id) orelse "Struct";
                    var buf = std.ArrayList(u8).initCapacity(alloc, 128) catch continue;
                    defer buf.deinit(alloc);
                    compat.listWriter(&buf, alloc).print("{s}(", .{struct_name}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) compat.listWriter(&buf, alloc).writeAll(", ") catch continue;
                        const bc = wgslNonFiniteBitcast(alloc, module, comp_id);
                        defer if (bc) |s| alloc.free(s);
                        const comp_name = bc orelse (names.get(comp_id) orelse "0.0");
                        compat.listWriter(&buf, alloc).writeAll(comp_name) catch continue;
                    }
                    compat.listWriter(&buf, alloc).writeAll(")") catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                } else if (ti.op == .TypeArray) {
                    // Array constant: emit as array<T, N>(v1, v2, ...)
                    var buf2 = std.ArrayList(u8).initCapacity(alloc, 128) catch continue;
                    defer buf2.deinit(alloc);
                    const elem_type_id = ti.words[2];
                    const count_id = ti.words[3];
                    const count_inst = getDef(module, count_id);
                    var count_val: u32 = 0;
                    if (count_inst) |ci2| {
                        if (ci2.op == .Constant and ci2.words.len > 3) count_val = ci2.words[3];
                    }
                    // This composite-constant naming is consumed ONLY by the WGSL
                    // backend (array<T,N>(...) is WGSL syntax), so the element type
                    // must use the fully-qualified WGSL type name. A VECTOR element
                    // needs `vecN<scalar>`, an ARRAY element `array<.., N>`, a STRUCT
                    // element its struct name — emitting the scalar fallback `f32`
                    // (e.g. `array<f32, 2>(array<vec4<f32>,2>(...), ...)` or
                    // `array<f32, 2>(Foobar(...), ...)`) is a type mismatch naga
                    // rejects. wgslTypeName() resolves all of these recursively.
                    const elem_name = wgslTypeName(alloc, module, names, elem_type_id) catch (alloc.dupe(u8, "f32") catch continue);
                    defer alloc.free(elem_name);
                    compat.listWriter(&buf2, alloc).print("array<{s}, {d}>(", .{ elem_name, count_val }) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) compat.listWriter(&buf2, alloc).writeAll(", ") catch continue;
                        const bc2 = wgslNonFiniteBitcast(alloc, module, comp_id);
                        defer if (bc2) |s| alloc.free(s);
                        const comp_name2 = bc2 orelse (names.get(comp_id) orelse "0.0");
                        compat.listWriter(&buf2, alloc).writeAll(comp_name2) catch continue;
                    }
                    compat.listWriter(&buf2, alloc).writeAll(")") catch continue;
                    const lit2 = buf2.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit2) catch null) |old| alloc.free(old.value);
                    continue;
                } else if (ti.op == .TypeMatrix) {
                    // Matrix constant: emit as matNxMf(col1, col2, ...)
                    const col_type_id = ti.words[2];
                    const col_count = if (ti.words.len > 3) ti.words[3] else 2;
                    const col_type_inst = getDef(module, col_type_id);
                    var col_size: u32 = 2;
                    if (col_type_inst) |ct| {
                        if (ct.op == .TypeVector and ct.words.len > 3) col_size = ct.words[3];
                    }
                    const scalar_type_id: u32 = if (col_type_inst) |ct| ct.words[2] else 0;
                    const scalar_type_raw = tryResolveTypeName(module, scalar_type_id);
                    // Convert to WGSL-style short names: float->f, int->i, uint->u
                    const scalar_type: []const u8 = if (std.mem.eql(u8, scalar_type_raw, "float")) "f" else if (std.mem.eql(u8, scalar_type_raw, "int")) "i" else if (std.mem.eql(u8, scalar_type_raw, "uint")) "u" else scalar_type_raw;
                    var buf3 = std.ArrayList(u8).initCapacity(alloc, 128) catch continue;
                    defer buf3.deinit(alloc);
                    compat.listWriter(&buf3, alloc).print("mat{d}x{d}{s}(", .{ col_count, col_size, scalar_type }) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) compat.listWriter(&buf3, alloc).writeAll(", ") catch continue;
                        const comp_name3 = names.get(comp_id) orelse "0.0";
                        compat.listWriter(&buf3, alloc).writeAll(comp_name3) catch continue;
                    }
                    compat.listWriter(&buf3, alloc).writeAll(")") catch continue;
                    const lit3 = buf3.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit3) catch null) |old| alloc.free(old.value);
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
}

pub fn tryResolveTypeName(module: *const ParsedModule, type_id: u32) []const u8 {
    const inst = getDef(module, type_id) orelse return "float";
    return switch (inst.op) {
        .TypeFloat => "float",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeBool => "bool",
        else => "float",
    };
}

/// Spell the fully-qualified WGSL type name for `type_id`, recursively. Used by
/// the WGSL ConstantComposite namer so an array/matrix/struct element gets its
/// real WGSL type (`vec4<f32>`, `array<vec4<f32>, 2>`, `Foobar`) instead of the
/// scalar fallback `f32` — emitting `array<f32, 2>(array<...>(...))` is a type
/// mismatch naga rejects. `names` supplies struct type names. Caller frees.
pub fn wgslTypeName(alloc: std.mem.Allocator, module: *const ParsedModule, names: *const std.AutoHashMap(u32, []const u8), type_id: u32) ![]const u8 {
    const inst = getDef(module, type_id) orelse return alloc.dupe(u8, "f32");
    switch (inst.op) {
        .TypeFloat => return alloc.dupe(u8, "f32"),
        .TypeInt => return alloc.dupe(u8, if (inst.words.len > 3 and inst.words[3] != 0) "i32" else "u32"),
        .TypeBool => return alloc.dupe(u8, "bool"),
        .TypeVector => {
            if (inst.words.len > 3) {
                const scalar = try wgslTypeName(alloc, module, names, inst.words[2]);
                defer alloc.free(scalar);
                return std.fmt.allocPrint(alloc, "vec{d}<{s}>", .{ inst.words[3], scalar });
            }
            return alloc.dupe(u8, "f32");
        },
        .TypeMatrix => {
            // words: [_, result, col_type, col_count]; col_type is a vector.
            if (inst.words.len > 3) {
                const col = getDef(module, inst.words[2]);
                const rows: u32 = if (col) |c| (if (c.op == .TypeVector and c.words.len > 3) c.words[3] else 4) else 4;
                return std.fmt.allocPrint(alloc, "mat{d}x{d}<f32>", .{ inst.words[3], rows });
            }
            return alloc.dupe(u8, "mat4x4<f32>");
        },
        .TypeArray => {
            const elem = try wgslTypeName(alloc, module, names, inst.words[2]);
            defer alloc.free(elem);
            var count_val: u32 = 0;
            if (getDef(module, inst.words[3])) |ci| {
                if (ci.op == .Constant and ci.words.len > 3) count_val = ci.words[3];
            }
            return std.fmt.allocPrint(alloc, "array<{s}, {d}>", .{ elem, count_val });
        },
        .TypeStruct => return alloc.dupe(u8, names.get(type_id) orelse "Struct"),
        else => return alloc.dupe(u8, "f32"),
    }
}

/// WGSL has no inf/nan float literal. If `id` is a non-finite 32-bit float
/// OpConstant, return its exact bit pattern as `bitcast<f32>(0x..u)` (caller
/// frees); otherwise null (caller uses the normal constant name). Used by the
/// WGSL-only ConstantComposite namer so a non-finite component does not leak the
/// bare `inf`/`nan` identifier naga rejects (#252).
fn wgslNonFiniteBitcast(alloc: std.mem.Allocator, module: *const ParsedModule, id: u32) ?[]const u8 {
    const ci = getDef(module, id) orelse return null;
    if (ci.op != .Constant or ci.words.len <= 3) return null;
    const ti = getDef(module, ci.words[1]) orelse return null;
    if (ti.op != .TypeFloat or !(ti.words.len > 2 and ti.words[2] == 32)) return null;
    const f: f32 = @bitCast(ci.words[3]);
    if (std.math.isFinite(f)) return null;
    return std.fmt.allocPrint(alloc, "bitcast<f32>(0x{x:0>8}u)", .{ci.words[3]}) catch null;
}

pub fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    // #476: width-aware — honest-error 64-bit (2-word truncation) and 16-bit float (low-
    // bits mis-bitcast); sign-extend signed int16. See spirv_to_glsl.zig for the rationale.
    if (type_inst.op == .TypeFloat and type_inst.words.len > 2) {
        const w = type_inst.words[2];
        if (w == 64) return error.UnsupportedConstantWidth;
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

pub fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, name.len);
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => buf.appendAssumeCapacity(c),
            else => buf.appendAssumeCapacity('_'),
        }
    }
    return buf.toOwnedSlice(alloc);
}

pub fn parseLiteralString(alloc: std.mem.Allocator, words: []const u32) ![]const u8 {
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

pub fn isUniformVariable(module: *const ParsedModule, id: u32) bool {
    const var_inst = getDef(module, id) orelse return false;
    if (var_inst.op != .Variable or var_inst.words.len < 4) return false;
    const sc: spirv.StorageClass = @enumFromInt(var_inst.words[3]);
    return sc == .Uniform;
}

pub fn swizzleChar(index: u32) []const u8 {
    return switch (index) {
        0 => "x",
        1 => "y",
        2 => "z",
        3 => "w",
        else => "?",
    };
}

// ---------------------------------------------------------------------------
// Unified Backend Helpers (used by GLSL, HLSL, MSL, WGSL backends)
// ---------------------------------------------------------------------------

/// Emit struct forward declarations for types referenced by a root type.
/// `ctx` is the backend's ParsedModule pointer. `type_fn(ctx, type_id, names, alloc)` and
/// `member_fn(ctx, struct_id, member_idx, buf)` are backend-specific.
pub fn commonEmitStructForwardDecls(
    ctx: anytype,
    names: *std.AutoHashMap(u32, []const u8),
    root_type_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    emitted: *std.AutoHashMap(u32, void),
    emitted_names: *std.StringHashMap(void),
    comptime type_fn: anytype,
    comptime member_fn: anytype,
) !void {
    const inst = localGetDef(ctx.instructions, ctx.id_defs, root_type_id) orelse return;
    if (inst.op != .TypeStruct) return;
    if (inst.words.len > 2) {
        for (inst.words[2..]) |mt_id| {
            try commonEmitOneStructForwardDecl(ctx, names, mt_id, w, alloc, emitted, emitted_names, type_fn, member_fn);
        }
    }
}

pub fn commonEmitOneStructForwardDecl(
    ctx: anytype,
    names: *std.AutoHashMap(u32, []const u8),
    type_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    emitted: *std.AutoHashMap(u32, void),
    emitted_names: *std.StringHashMap(void),
    comptime type_fn: anytype,
    comptime member_fn: anytype,
) !void {
    const instructions = ctx.instructions;
    const id_defs = ctx.id_defs;
    const inst = localGetDef(instructions, id_defs, type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            if (inst.words.len > 2) {
                for (inst.words[2..]) |mt_id| {
                    try commonEmitOneStructForwardDecl(ctx, names, mt_id, w, alloc, emitted, emitted_names, type_fn, member_fn);
                }
            }
            if (emitted.get(type_id) != null) return;
            const sname = names.get(type_id) orelse "Struct";
            if (emitted_names.get(sname) != null) return;
            emitted.put(type_id, {}) catch return;
            try emitted_names.put(sname, {});
            try w.print("struct {s}\n{{\n", .{sname});
            for (inst.words[2..], 0..) |mt_id, mi| {
                const mti = localGetDef(instructions, id_defs, mt_id);
                if (mti) |mi2| {
                    if (mi2.op == .TypeArray and mi2.words.len > 3) {
                        const et = try type_fn(ctx, mi2.words[2], names, alloc);
                        const li = localGetDef(instructions, id_defs, mi2.words[3]);
                        const lv: u32 = if (li) |l| l.words[3] else 1;
                        var mname_buf: [32]u8 = undefined;
                        const mname = member_fn(ctx, type_id, @as(u32, @intCast(mi)), &mname_buf);
                        try w.print("    {s} {s}[{d}];\n", .{ et, mname, lv });
                        continue;
                    }
                }
                const mt = try type_fn(ctx, mt_id, names, alloc);
                var mname_buf: [32]u8 = undefined;
                const mname = member_fn(ctx, type_id, @as(u32, @intCast(mi)), &mname_buf);
                try w.print("    {s} {s};\n", .{ mt, mname });
            }
            try w.writeAll("};\n");
        },
        // TypeRuntimeArray shares the element-type word layout with TypeArray
        // (words[2]); without it an SSBO tail array `T elems[]` never recurses
        // into T, so the struct is emitted after its first use (#418).
        .TypeArray, .TypeRuntimeArray => if (inst.words.len > 2) try commonEmitOneStructForwardDecl(ctx, names, inst.words[2], w, alloc, emitted, emitted_names, type_fn, member_fn),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try commonEmitOneStructForwardDecl(ctx, names, inst.words[2], w, alloc, emitted, emitted_names, type_fn, member_fn),
        else => {},
    }
}

/// Get array dimension suffix for a pointer type. E.g., "[4]" or "[2][3]" for multi-dim.
/// HLSL uses multi_dim=true to unwrap nested TypeArray layers.
/// Takes instruction slice + id_defs to work across different ParsedModule types.
pub fn commonGetArraySuffix(instructions: anytype, id_defs: anytype, ptr_type_id: u32, multi_dim: bool) ![]const u8 {
    const ptr_inst = localGetDef(instructions, id_defs, ptr_type_id) orelse return "";
    if (ptr_inst.op != .TypePointer or ptr_inst.words.len <= 3) return "";

    if (!multi_dim) {
        const pointee_id = ptr_inst.words[3];
        const pt_inst = localGetDef(instructions, id_defs, pointee_id) orelse return "";
        if (pt_inst.op == .TypeArray and pt_inst.words.len > 3) {
            const len_id = pt_inst.words[3];
            const len_def = localGetDef(instructions, id_defs, len_id);
            if (len_def) |ld| {
                // OpSpecConstant has the same word layout as OpConstant (words[3] = the
                // literal default), so a spec-constant-length array specializes to its
                // default size — a valid compile-time dimension. (OpSpecConstantOp is
                // excluded: words[3] is an opcode, not a literal.) #475
                if ((ld.op == .Constant or ld.op == .SpecConstant) and ld.words.len > 3) {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "[{d}]", .{ld.words[3]}) catch return "";
                    return try std.heap.page_allocator.dupe(u8, s);
                }
            }
        }
        return "";
    }

    // Multi-dimension path (HLSL): collect all nested TypeArray dimensions
    var dims: [4]u32 = undefined;
    var dim_count: usize = 0;
    var current_id = ptr_inst.words[3];
    while (dim_count < dims.len) {
        const pt_inst = localGetDef(instructions, id_defs, current_id) orelse break;
        if (pt_inst.op != .TypeArray or pt_inst.words.len <= 3) break;
        const len_id = pt_inst.words[3];
        const len_def = localGetDef(instructions, id_defs, len_id);
        if (len_def) |ld| {
            if ((ld.op == .Constant or ld.op == .SpecConstant) and ld.words.len > 3) {
                dims[dim_count] = ld.words[3];
                dim_count += 1;
            } else break;
        } else break;
        current_id = pt_inst.words[2];
    }
    if (dim_count == 0) return "";

    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    for (dims[0..dim_count]) |d| {
        const part = std.fmt.bufPrint(buf[pos..], "[{d}]", .{d}) catch break;
        pos += part.len;
    }
    const suffix = buf[0..pos];
    return try std.heap.page_allocator.dupe(u8, suffix);
}

pub fn localGetDef(instructions: anytype, id_defs: anytype, id: u32) ?@TypeOf(instructions[0]) {
    const idx = if (id < id_defs.len) id_defs[id] orelse return null else return null;
    if (idx >= instructions.len) return null;
    return instructions[idx];
}

/// Resolve an OpTypeArray length id to a concrete u32 for backends that have no
/// specialization constants (HLSL/GLSL/MSL). OpConstant/OpSpecConstant -> their
/// literal/default (words[3]); OpSpecConstantOp -> evaluated using operand defaults
/// (IAdd/ISub/IMul of leaf constants, e.g. `const int d = c + 50;` -> c's default
/// + 50). Returns null for shapes it can't evaluate so the caller can honest-error
/// rather than emit a wrong size. `module` is anytype (HLSL's own ParsedModule
/// shares the .instructions/.id_defs shape).
pub fn arrayLengthValue(module: anytype, len_id: u32) ?u32 {
    return arrayLenEval(module, len_id, 0);
}
fn arrayLenEval(module: anytype, len_id: u32, depth: u32) ?u32 {
    if (depth > 8) return null;
    const def = localGetDef(module.instructions, module.id_defs, len_id) orelse return null;
    switch (def.op) {
        .Constant, .SpecConstant => return if (def.words.len > 3) def.words[3] else null,
        .SpecConstantOp => {
            // words layout: [hdr, result_type, result_id, opcode, operand1, operand2, ...]
            if (def.words.len < 6) return null;
            const oc = def.words[3];
            const a = arrayLenEval(module, def.words[4], depth + 1) orelse return null;
            const b = arrayLenEval(module, def.words[5], depth + 1) orelse return null;
            if (oc == @intFromEnum(spirv.Op.IAdd)) return a +% b;
            if (oc == @intFromEnum(spirv.Op.ISub)) return a -% b;
            if (oc == @intFromEnum(spirv.Op.IMul)) return a *% b;
            return null;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Unified Backend Helpers (used by GLSL, HLSL, MSL, WGSL backends)
// ---------------------------------------------------------------------------

/// Get the name of a struct member from OpMemberName, with configurable fallback prefix.
/// GLSL uses "m" (m0, m1, ...), HLSL/MSL use "_m" (_m0, _m1, ...)
/// Takes instruction slice directly to work across different ParsedModule types.
pub fn commonGetMemberName(instructions: anytype, struct_id: u32, member_idx: u32, buf: *[32]u8, fallback_prefix: []const u8) []const u8 {
    for (instructions) |inst| {
        if (inst.op == .MemberName and inst.words.len >= 4 and inst.words[1] == struct_id and inst.words[2] == member_idx) {
            var name_len: usize = 0;
            for (inst.words[3..]) |word| {
                const bytes = std.mem.asBytes(&word);
                for (bytes) |b| {
                    if (b == 0) break;
                    if (name_len < buf.len - 1) {
                        buf[name_len] = b;
                        name_len += 1;
                    }
                }
            }
            // Sanitize in place: OpMemberName bytes can contain chars that are
            // invalid in every target-language identifier. The HLSL frontend, for
            // example, writes "@data" for an anonymous RWStructuredBuffer member (the
            // @ flags compiler-generated). Variable names (OpName) are already routed
            // through sanitizeName; member names must be too, or they reach the page
            // verbatim and become invalid/undeclared identifiers downstream. Invalid
            // chars map 1:1 to '_' (no buffer growth, so in place on the same buf).
            for (buf[0..name_len]) |*c| switch (c.*) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => c.* = '_',
            };
            if (name_len > 0) return buf[0..name_len];
        }
    }
    return std.fmt.bufPrint(buf, "{s}{d}", .{ fallback_prefix, member_idx }) catch fallback_prefix;
}

// ---------------------------------------------------------------------------
// Resource collection (backend-agnostic)
// ---------------------------------------------------------------------------

pub const CbufferDecl = struct {
    name: []const u8,
    type_id: u32,
    binding: u32,
};

pub const TextureDecl = struct {
    name: []const u8,
    binding: u32,
    /// SPIR-V image type instruction
    image_type_id: u32,
    /// The type ID of the sampled image or image
    pointee_type_id: u32,
};

pub fn collectResources(
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
            .Uniform => {
                const binding = getDecorationValue(decorations, result_id, .binding) orelse 0;
                const name = names.get(result_id) orelse "Globals";
                cbuffers.append(alloc, .{
                    .name = name,
                    .type_id = pointee_type,
                    .binding = binding,
                }) catch {};
            },
            .UniformConstant => {
                const pointee_inst = getDef(module, pointee_type) orelse continue;
                const binding = getDecorationValue(decorations, result_id, .binding) orelse 0;
                const name = names.get(result_id) orelse "tex";
                switch (pointee_inst.op) {
                    .TypeSampledImage => {
                        if (pointee_inst.words.len < 3) continue;
                        textures.append(alloc, .{
                            .name = name,
                            .binding = binding,
                            .image_type_id = pointee_inst.words[2],
                            .pointee_type_id = pointee_type,
                        }) catch {};
                    },
                    .TypeImage => {
                        textures.append(alloc, .{
                            .name = name,
                            .binding = binding,
                            .image_type_id = pointee_type,
                            .pointee_type_id = pointee_type,
                        }) catch {};
                    },
                    .TypeSampler => continue,
                    else => continue,
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Shared Parse Cache
// ---------------------------------------------------------------------------
// Avoids re-parsing the same SPIR-V binary when multiple backends are called
// sequentially (e.g., spirvToHLSL → spirvToGLSL → spirvToMSL).
// Thread-local for safety. Keyed on words pointer + length.

threadlocal var _shared_cache_mod: ?ParsedModule = null;
threadlocal var _shared_cache_ptr: ?[*]const u32 = null;
threadlocal var _shared_cache_len: usize = 0;
threadlocal var _shared_cache_alloc: ?std.mem.Allocator = null;

pub fn getCachedParse(alloc: std.mem.Allocator, spirv_words: []const u32) !ParsedModule {
    if (_shared_cache_ptr) |p| {
        if (p == spirv_words.ptr and _shared_cache_len == spirv_words.len and _shared_cache_mod != null) {
            return _shared_cache_mod.?;
        }
    }
    // Evict old cache
    if (_shared_cache_mod) |*old| {
        if (_shared_cache_alloc) |a| old.deinit(a);
        _shared_cache_mod = null;
    }
    const m = try parseModule(alloc, spirv_words);
    _shared_cache_mod = m;
    _shared_cache_ptr = spirv_words.ptr;
    _shared_cache_len = spirv_words.len;
    _shared_cache_alloc = alloc;
    return m;
}

// ---------------------------------------------------------------------------
// Binding shift helper (M8.3)
// ---------------------------------------------------------------------------
//
// Apply a signed shift to a SPIR-V descriptor binding number. Used by
// the GLSL/MSL/WGSL backends to remap binding spaces between APIs (e.g.
// when a host engine reserves binding=0 for its own resources and shaders
// must be shifted up by one).
//
// Mirrors the i32 signed-add semantics of `HlslCompileOptions.binding_shift`.
// Results that go negative clamp to 0 (HLSL's behaviour at the binding emit
// point); going below zero would otherwise be a nonsense binding index.

/// Apply a signed binding shift, clamping negative results to 0.
pub fn applyBindingShift(binding: u32, shift: i32) u32 {
    const widened: i64 = @as(i64, binding) + @as(i64, shift);
    if (widened <= 0) return 0;
    if (widened > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(widened);
}

test "applyBindingShift: identity" {
    try std.testing.expectEqual(@as(u32, 5), applyBindingShift(5, 0));
}

test "applyBindingShift: negative shift" {
    try std.testing.expectEqual(@as(u32, 1), applyBindingShift(2, -1));
    try std.testing.expectEqual(@as(u32, 0), applyBindingShift(0, -1));
    try std.testing.expectEqual(@as(u32, 0), applyBindingShift(1, -2));
}

test "applyBindingShift: positive shift" {
    try std.testing.expectEqual(@as(u32, 7), applyBindingShift(2, 5));
}

// ---------------------------------------------------------------------------
// #413: loop-carried phi declaration hoisting (HLSL/GLSL/MSL text backends)
// ---------------------------------------------------------------------------
//
// The rotated-loop emission (#237) runs the phi carry copies at the TOP of
// the `while (true)` body, guarded by a first-iteration flag, so a `continue`
// still advances the carried values. When a phi's UPDATE value is defined
// inside the loop (body, condition block, or a Pattern-B header replayed
// inside the loop), that copy reads the update temp before its declaration
// and outside its scope — dxc/glslang/Metal reject the output with an
// undeclared-identifier error (#413). The fix is a declare-then-assign split:
// the update temp's declaration is hoisted just above the loop header and its
// defining instruction emits a plain assignment.

/// A phi update temp whose declaration is hoisted above its loop.
pub const HoistedPhiSrc = struct { id: u32, type_id: u32 };

/// Whether the update value `update_id` of a loop-header phi of the loop
/// whose OpLoopMerge sits at `loop_idx` needs its declaration hoisted above
/// the loop: true when the defining instruction is emitted INSIDE the loop.
/// Continue-block instructions are excluded — they are emitted inside the
/// top-of-loop guard BEFORE the carry copies, so they are already declared
/// (and in scope) when read.
pub fn loopPhiUpdateNeedsHoist(
    instructions: anytype,
    id_defs: anytype,
    label_map: *const std.AutoHashMap(u32, usize),
    deferred_hdr: *const std.AutoHashMap(usize, void),
    loop_idx: usize,
    update_id: u32,
) bool {
    if (loop_idx >= instructions.len) return false;
    const minst = instructions[loop_idx];
    if (minst.words.len < 3) return false;
    const def_idx = if (update_id < id_defs.len) (id_defs[update_id] orelse return false) else return false;
    // Pattern-B loop headers are skipped at their original position and
    // replayed inside their loop — an update defined there is body-scoped too.
    if (deferred_hdr.contains(def_idx)) return true;
    if (def_idx <= loop_idx) return false;
    if (label_map.get(minst.words[2])) |cs| {
        var ce = cs + 1;
        while (ce < instructions.len) : (ce += 1) {
            const t = instructions[ce];
            if (t.op == .Label or t.op == .FunctionEnd or t.op == .Branch or t.op == .BranchConditional) break;
        }
        if (def_idx > cs and def_idx < ce) return false;
    }
    return true;
}

/// Re-print a rendered `<indent><type> <name> = <expr>;` declaration with the
/// leading type stripped (the declaration was hoisted above the loop). Lines
/// before the declaration line pass through unchanged; if the pattern is not
/// found the buffer passes through verbatim (fail-safe: worst case is the
/// pre-hoist output, never corrupted text).
pub fn writeHoistedAssign(w: anytype, rendered: []const u8, name: []const u8) !void {
    if (name.len > 0 and name.len <= 56) {
        var nbuf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&nbuf, " {s} = ", .{name}) catch {
            try w.writeAll(rendered);
            return;
        };
        if (std.mem.indexOf(u8, rendered, needle)) |pos| {
            const line_start = if (std.mem.lastIndexOfScalar(u8, rendered[0..pos], '\n')) |nl| nl + 1 else 0;
            try w.writeAll(rendered[0..line_start]);
            try w.writeAll("    ");
            try w.writeAll(rendered[pos + 1 ..]);
            return;
        }
    }
    try w.writeAll(rendered);
}

test "writeHoistedAssign strips the type from a declaration line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeHoistedAssign(compat.listWriter(&buf, std.testing.allocator), "    float v106 = v98 + v103;\n", "v106");
    try std.testing.expectEqualStrings("    v106 = v98 + v103;\n", buf.items);
}

test "writeHoistedAssign passes unknown shapes through verbatim" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try writeHoistedAssign(compat.listWriter(&buf, std.testing.allocator), "    foo(v106);\n", "v106");
    try std.testing.expectEqualStrings("    foo(v106);\n", buf.items);
}

// ---------------------------------------------------------------------------
// Do-while back-edge analysis + condition inlining (#77, #246).
// Shared by the MSL/GLSL/HLSL backends. `module` is `anytype` because HLSL
// carries its own ParsedModule struct (all three share the .instructions /
// .id_defs shape used by localGetDef). `std450_name` is each backend's
// GLSL.std.450 name resolver (std450ToMsl/Glsl/Hlsl) so ExtInst operands
// inline with correct per-target naming; passed as anytype because the HLSL
// resolver takes the GLSLstd450 enum while MSL/GLSL take u32.
// ---------------------------------------------------------------------------
pub fn inlineDoWhileOperand(module: anytype, names: *std.AutoHashMap(u32, []const u8), id: u32, alloc: std.mem.Allocator, std450_name: anytype) ?[]const u8 {
    const def = localGetDef(module.instructions, module.id_defs, id) orelse return null;
    switch (def.op) {
        .Load => return if (def.words.len > 3) names.get(def.words[3]) else null,
        .Constant => return if (def.words.len > 3) names.get(def.words[2]) else null,
        .ConstantTrue => return "true",
        .ConstantFalse => return "false",
        // Arithmetic inside the condition (`zx*zx + zy*zy < 4.0`, a magnitude/distance
        // test that is ubiquitous in iteration loops) is rebuilt recursively over the
        // persistent vars, fully parenthesised so precedence matches the source. Strings
        // are arena-owned (freed at backend deinit).
        .FAdd, .IAdd, .FSub, .ISub, .FMul, .IMul, .FDiv, .SDiv, .UDiv => {
            if (def.words.len < 5) return null;
            const l = inlineDoWhileOperand(module, names, def.words[3], alloc, std450_name) orelse return null;
            const r = inlineDoWhileOperand(module, names, def.words[4], alloc, std450_name) orelse return null;
            const bop: []const u8 = switch (def.op) {
                .FAdd, .IAdd => "+",
                .FSub, .ISub => "-",
                .FMul, .IMul => "*",
                else => "/",
            };
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, bop, r }) catch null;
        },
        .FNegate, .SNegate => {
            if (def.words.len < 4) return null;
            const x = inlineDoWhileOperand(module, names, def.words[3], alloc, std450_name) orelse return null;
            return std.fmt.allocPrint(alloc, "(-{s})", .{x}) catch null;
        },
        // #77: pure unary GLSL.std.450 calls inside a do-while back-edge condition
        // (`abs(sum) < 0.4`) rebuild as `name(arg)` over the recursively-inlined operand.
        // Reuses the passed-in std450 resolver (each backend's emitStd450 table) so every
        // unary pure function the target supports is covered (tan/asin/exp/log/rsqrt/...)
        // and per-target naming is correct. words.len==6 restricts to unary (binary ops like powr/atan2 have >=7).
        // Vector-only ops (length/distance/cross/normalize/faceforward/reflect/refract) are
        // excluded: their SCALAR forms need the special lowering emitStd450 does (e.g. scalar
        // length -> abs), which a bare name call would skip -> invalid for a scalar operand;
        // they honest-error here (as they did before this arm existed).
        .ExtInst => {
            if (def.words.len != 6) return null; // unary only (type,result,set,inst,arg0)
            const op = def.words[4];
            switch (op) {
                66, 67, 68, 69, 70, 71, 72 => return null,
                else => {},
            } // vector-only
            const nm = std450_name(op) orelse return null;
            const arg = inlineDoWhileOperand(module, names, def.words[5], alloc, std450_name) orelse return null;
            return std.fmt.allocPrint(alloc, "{s}({s})", .{ nm, arg }) catch null;
        },
        else => return null,
    }
}

/// Rebuild a do-while back-edge condition as an inline MSL expression over persistent
/// variables (#246): a single comparison `a OP b` whose operands are loads-of-vars or
/// constants. Returns null for compound (`&&`/`||`) or non-trivial conditions so the
/// caller falls back to the honest-error path.
pub fn tryInlineDoWhileCond(
    module: anytype,
    names: *std.AutoHashMap(u32, []const u8),
    cond_id: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    alloc: std.mem.Allocator,
    std450_name: anytype,
) ?[]const u8 {
    const def = localGetDef(module.instructions, module.id_defs, cond_id) orelse return null;
    // #77: a short-circuit && / || back-edge condition is emitted by glslang as an OpPhi
    // of two bools at the selection-merge block (one incoming per short-circuit path).
    // Rebuild it faithfully as a ternary over the short-circuit router's condition.
    if (def.op == .Phi) return inlineShortCircuitPhi(module, names, cond_id, label_map, alloc, std450_name);
    const op_str: ?[]const u8 = switch (def.op) {
        .SLessThan, .ULessThan, .FOrdLessThan => "<",
        .SGreaterThan, .UGreaterThan, .FOrdGreaterThan => ">",
        .SLessThanEqual, .ULessThanEqual, .FOrdLessThanEqual => "<=",
        .SGreaterThanEqual, .UGreaterThanEqual, .FOrdGreaterThanEqual => ">=",
        .IEqual, .FOrdEqual => "==",
        // glslang lowers every MSL/GLSL float `!=` to the UNORDERED OpFUnordNotEqual,
        // and `!=` is itself unordered (true on NaN) → an exact 1:1 match. Only
        // FUnordNotEqual is added here: the other FUnord* compares have no ordered-
        // operator equivalent (==,<,>,<=,>= are all ordered, NaN→false), so this inline
        // path deliberately leaves them to honest-error rather than risk a NaN-silent-
        // wrong mapping. (#170)
        .INotEqual, .FOrdNotEqual, .FUnordNotEqual => "!=",
        else => null,
    };
    if (op_str) |ops| {
        if (def.words.len < 5) return null;
        const lhs = inlineDoWhileOperand(module, names, def.words[3], alloc, std450_name) orelse return null;
        const rhs = inlineDoWhileOperand(module, names, def.words[4], alloc, std450_name) orelse return null;
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lhs, ops, rhs }) catch null;
    }
    // Compound conditions (`n < 20 && x < 4.0`) lower to OpLogicalAnd/Or over two
    // comparison results; a do-while whose back-edge test is compound is common in
    // iteration loops (fractal/raymarch). Rebuild each side recursively and join. The
    // SPIR-V is eager (both operands are side-effect-free comparisons), so `&&`/`||`
    // over them is equivalent even though MSL short-circuits.
    if (def.op == .LogicalAnd or def.op == .LogicalOr) {
        if (def.words.len < 5) return null;
        const lhs = tryInlineDoWhileCond(module, names, def.words[3], label_map, alloc, std450_name) orelse return null;
        const rhs = tryInlineDoWhileCond(module, names, def.words[4], label_map, alloc, std450_name) orelse return null;
        const jop: []const u8 = if (def.op == .LogicalAnd) "&&" else "||";
        return std.fmt.allocPrint(alloc, "({s}) {s} ({s})", .{ lhs, jop, rhs }) catch null;
    }
    if (def.op == .LogicalNot and def.words.len >= 4) {
        const inner = tryInlineDoWhileCond(module, names, def.words[3], label_map, alloc, std450_name) orelse return null;
        return std.fmt.allocPrint(alloc, "!({s})", .{inner}) catch null;
    }
    if (def.op == .Load and def.words.len > 3) return names.get(def.words[3]);
    return null;
}

pub const DwRouter = struct { cond: u32, true_t: u32, false_t: u32 };

/// Find the short-circuit router BranchConditional inside `pred_lbl`'s block: the one
/// whose targets include `other_pred`. Returns its condition + targets, else null.
pub fn dwFindRouter(
    module: anytype,
    pred_lbl: u32,
    other_pred: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) ?DwRouter {
    const bi = label_map.get(pred_lbl) orelse return null;
    var k: usize = bi + 1;
    while (k < module.instructions.len) : (k += 1) {
        const u = module.instructions[k];
        if (u.op == .Label or u.op == .FunctionEnd) break;
        if (u.op == .Branch) break;
        if (u.op == .BranchConditional and u.words.len >= 4) {
            if (u.words[2] == other_pred or u.words[3] == other_pred) {
                return .{ .cond = u.words[1], .true_t = u.words[2], .false_t = u.words[3] };
            }
            break; // a BranchConditional not routing to other_pred = not the short-circuit shape
        }
    }
    return null;
}

/// #77: rebuild a short-circuit OpPhi-of-bools (a do-while && / || back-edge condition)
/// as a faithful ternary `cond ? <cond-true incoming> : <cond-false incoming>` over the
/// short-circuit router's condition. The phi has exactly two (value, pred) incomings;
/// one pred is the structural block (holds the router OpSelectionMerge+BranchConditional),
/// the other is the eval sub-block. The router's condition + which of its targets is the
/// eval block determine the ternary arms — polarity-agnostic (correct for && when the
/// eval block is the cond-true target, and || when it is the cond-false target), so no
/// operator need be labelled. Returns null (→ honest-error) for any other shape.
pub fn inlineShortCircuitPhi(
    module: anytype,
    names: *std.AutoHashMap(u32, []const u8),
    phi_id: u32,
    label_map: *const std.AutoHashMap(u32, usize),
    alloc: std.mem.Allocator,
    std450_name: anytype,
) ?[]const u8 {
    const phi = localGetDef(module.instructions, module.id_defs, phi_id) orelse return null;
    // OpPhi layout: [type, result, val0, pred0, val1, pred1] → exactly 2 incomings here.
    if (phi.op != .Phi or phi.words.len != 7) return null;
    const v0 = phi.words[3];
    const p0 = phi.words[4];
    const v1 = phi.words[5];
    const p1 = phi.words[6];
    // The router lives in the structural pred (its block branches to the other pred).
    const router = dwFindRouter(module, p0, p1, label_map) orelse
        dwFindRouter(module, p1, p0, label_map) orelse return null;
    // The eval block is the router target that is also one of the phi's preds; the merge
    // (the phi's own block) is the other router target.
    const eval_is_p0 = (router.true_t == p0 or router.false_t == p0);
    const eval_is_p1 = (router.true_t == p1 or router.false_t == p1);
    if (eval_is_p0 == eval_is_p1) return null; // router must target EXACTLY one pred (the eval block); both-or-neither is ambiguous/not our shape
    const eval_val: u32 = if (eval_is_p0) v0 else v1;
    const struct_val: u32 = if (eval_is_p0) v1 else v0; // incoming from the structural pred
    // cond-true leads to whichever router target is the eval block; cond-false reaches the
    // merge via the structural pred. Map the ternary arms accordingly.
    const true_target_is_eval = (router.true_t == p0 or router.true_t == p1);
    const tv: u32 = if (true_target_is_eval) eval_val else struct_val;
    const fv: u32 = if (true_target_is_eval) struct_val else eval_val;
    const cond = tryInlineDoWhileCond(module, names, router.cond, label_map, alloc, std450_name) orelse return null;
    const tve = tryInlineDoWhileCond(module, names, tv, label_map, alloc, std450_name) orelse return null;
    const fve = tryInlineDoWhileCond(module, names, fv, label_map, alloc, std450_name) orelse return null;
    return std.fmt.allocPrint(alloc, "({s}) ? ({s}) : ({s})", .{ cond, tve, fve }) catch null;
}

/// A do-while (bottom-test) loop's CONTINUE block ends in a back-edge
/// `OpBranchConditional` whose two targets are exactly {header, merge}. A normal
/// top-test loop's continue block ends in an unconditional `OpBranch header`.
/// Returns the index of that back-edge BranchConditional, else null. Must be
/// consulted BEFORE scanning the body for a condition (#244): otherwise a
/// body-local `if` is mis-detected as the loop condition.
pub fn detectDoWhileBackEdge(
    module: anytype,
    cont_lbl: u32,
    header_lbl: u32,
    merge_lbl: u32,
    label_map: *const std.AutoHashMap(u32, usize),
) ?usize {
    const ci = label_map.get(cont_lbl) orelse return null;
    var s = ci + 1;
    // #77: a short-circuit && / || back-edge condition lowers (glslang) to a NESTED
    // OpSelectionMerge inside the continue block, so the continue is no longer a
    // single block: <cond-A>; OpSelectionMerge M; OpBranchConditional A, eval, M;
    // eval: <cond-B>; OpBranch M; M: %phi = OpPhi bool; OpBranchConditional phi, hdr, merge.
    // Track the nested selection-merge target so the short-circuit router below is
    // recognised and the REAL back-edge (the terminator of M) is found.
    var sel_merge_lbl: ?u32 = null;
    while (s < module.instructions.len) : (s += 1) {
        const t = module.instructions[s];
        if (t.op == .Label or t.op == .FunctionEnd) return null;
        if (t.op == .Branch) return null; // unconditional back-edge = top-test loop
        if (t.op == .SelectionMerge and t.words.len >= 2) {
            sel_merge_lbl = t.words[1];
            continue;
        }
        if (t.op == .BranchConditional and t.words.len >= 4) {
            const a = t.words[2];
            const b = t.words[3];
            if ((a == header_lbl and b == merge_lbl) or (a == merge_lbl and b == header_lbl)) return s;
            // #77: this BranchConditional is the short-circuit router (its targets are
            // the eval sub-block + the selection merge), NOT the loop back-edge. The
            // real back-edge is the BranchConditional terminator of the selection-merge
            // block. Descend to it; if the shape doesn't match, fall through to null.
            if (sel_merge_lbl) |sml| {
                if (label_map.get(sml)) |smi| {
                    var k: usize = smi + 1;
                    while (k < module.instructions.len) : (k += 1) {
                        const u = module.instructions[k];
                        if (u.op == .Label or u.op == .FunctionEnd or u.op == .Branch) break;
                        if (u.op == .BranchConditional and u.words.len >= 4) {
                            const c = u.words[2];
                            const d = u.words[3];
                            if ((c == header_lbl and d == merge_lbl) or (c == merge_lbl and d == header_lbl)) return k;
                            break;
                        }
                    }
                }
            }
            return null;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Shared binary-op + function-call emission (#emitBinOp/#emitCall).
// Used by the MSL/GLSL/HLSL backends. `module` is `anytype` (HLSL's own
// ParsedModule shares the .instructions/.id_defs shape); `type_name` is each
// backend's type-name resolver (mslType/glslType/hlslType, uniform signature),
// threaded in so the result-type spelling is per-target.
// ---------------------------------------------------------------------------
pub fn emitBinOp(module: anytype, names: *std.AutoHashMap(u32, []const u8), inst: anytype, op: []const u8, w: anytype, alloc: std.mem.Allocator, type_name: anytype) !void {
    const rtt = try type_name(module, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s} {s} {s};\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "a", op, names.get(inst.words[4]) orelse "b" });
}

pub fn emitCall(module: anytype, names: *std.AutoHashMap(u32, []const u8), inst: anytype, func: []const u8, w: anytype, alloc: std.mem.Allocator, type_name: anytype) !void {
    const rtt = try type_name(module, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[3..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}
