// SPDX-License-Identifier: MIT OR Apache-2.0
//! Shared SPIR-V cross-compiler infrastructure.
//!
//! This module provides the SPIR-V binary parser, type/annotation resolution,
//! and helper utilities used by all cross-compilation backends (HLSL, GLSL, MSL).

const std = @import("std");
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
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix,
        .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray,
        .TypeStruct, .TypePointer, .TypeFunction, .TypeForwardPointer,
        .TypeAccelerationStructureKHR, .TypeRayQueryKHR, .TypeTensorARM,
        => if (words.len > 1) words[1] else null,

        .ConstantTrue, .ConstantFalse, .Constant, .ConstantComposite,
        .SpecConstant, .SpecConstantTrue, .SpecConstantFalse,
        .SpecConstantComposite, .SpecConstantOp, .Undef,
        => if (words.len > 2) words[2] else null,

        .Variable, .Function, .FunctionParameter,
        => if (words.len > 2) words[2] else null,

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

pub fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    const idx = if (id < module.id_defs.len) module.id_defs[id] orelse return null else return null;
    if (idx >= module.instructions.len) return null;
    return module.instructions[idx];
}

/// True if the module declares a `UniformConstant` resource that is an ARRAY of an
/// opaque type (sampler / image / sampled-image) — e.g. `uniform sampler2D tex[4]`.
/// Backends that don't yet support descriptor arrays use this to honest-error
/// rather than emit broken output. (The GLSL backend DOES support them.)
pub fn hasOpaqueArrayResource(module: *const ParsedModule) bool {
    for (module.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        if (sc != .UniformConstant) continue;
        const ptr = getDef(module, inst.words[1]) orelse continue;
        if (ptr.op != .TypePointer or ptr.words.len < 4) continue;
        const pe = getDef(module, ptr.words[3]) orelse continue;
        if (pe.op != .TypeArray or pe.words.len < 3) continue;
        const el = getDef(module, pe.words[2]) orelse continue;
        if (el.op == .TypeSampledImage or el.op == .TypeSampler or el.op == .TypeImage) return true;
    }
    return false;
}

pub fn getTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(module, id) orelse return null;
    return switch (inst.op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix,
        .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray,
        .TypeStruct, .TypePointer, .TypeFunction,
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
                    buf.writer(alloc).print("vec{d}<{s}>(", .{count, wgsl_scalar}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf.writer(alloc).writeAll(", ") catch continue;
                        const comp_name = names.get(comp_id) orelse "0.0";
                        buf.writer(alloc).writeAll(comp_name) catch continue;
                    }
                    buf.writer(alloc).writeAll(")") catch continue;
                    const lit = buf.toOwnedSlice(alloc) catch continue;
                    if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    continue;
                } else if (ti.op == .TypeStruct) {
                    // Struct constant: emit as StructName(field1, field2, ...)
                    const struct_name = names.get(type_id) orelse "Struct";
                    var buf = std.ArrayList(u8).initCapacity(alloc, 128) catch continue;
                    defer buf.deinit(alloc);
                    buf.writer(alloc).print("{s}(", .{struct_name}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf.writer(alloc).writeAll(", ") catch continue;
                        const comp_name = names.get(comp_id) orelse "0.0";
                        buf.writer(alloc).writeAll(comp_name) catch continue;
                    }
                    buf.writer(alloc).writeAll(")") catch continue;
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
                    // must use WGSL names — tryResolveTypeName returns the GLSL
                    // spelling ("float"/"int"/"uint"), which would leak as a bare
                    // identifier naga rejects ("no definition in scope: float").
                    // A VECTOR element (e.g. `vec3 palette[4]`) must spell the full
                    // `vecN<scalar>`, not just the scalar — emitting `array<f32, 4>`
                    // for a vec3[4] is a type mismatch naga rejects (the args are
                    // `vec3<f32>(...)`). Matrix elements are rare; fall back to the
                    // resolved name.
                    var elem_buf: [32]u8 = undefined;
                    const elem_inst = getDef(module, elem_type_id);
                    const elem_name: []const u8 = blk2: {
                        if (elem_inst) |ei| {
                            if (ei.op == .TypeVector and ei.words.len > 3) {
                                const comp_raw = tryResolveTypeName(module, ei.words[2]);
                                const ws: []const u8 = if (std.mem.eql(u8, comp_raw, "float")) "f32" else if (std.mem.eql(u8, comp_raw, "int")) "i32" else if (std.mem.eql(u8, comp_raw, "uint")) "u32" else comp_raw;
                                break :blk2 std.fmt.bufPrint(&elem_buf, "vec{d}<{s}>", .{ ei.words[3], ws }) catch "f32";
                            }
                        }
                        const elem_raw = tryResolveTypeName(module, elem_type_id);
                        break :blk2 if (std.mem.eql(u8, elem_raw, "float")) "f32" else if (std.mem.eql(u8, elem_raw, "int")) "i32" else if (std.mem.eql(u8, elem_raw, "uint")) "u32" else elem_raw; // "bool" is identical in WGSL
                    };
                    buf2.writer(alloc).print("array<{s}, {d}>(", .{elem_name, count_val}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf2.writer(alloc).writeAll(", ") catch continue;
                        const comp_name2 = names.get(comp_id) orelse "0.0";
                        buf2.writer(alloc).writeAll(comp_name2) catch continue;
                    }
                    buf2.writer(alloc).writeAll(")") catch continue;
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
                    buf3.writer(alloc).print("mat{d}x{d}{s}(", .{col_count, col_size, scalar_type}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf3.writer(alloc).writeAll(", ") catch continue;
                        const comp_name3 = names.get(comp_id) orelse "0.0";
                        buf3.writer(alloc).writeAll(comp_name3) catch continue;
                    }
                    buf3.writer(alloc).writeAll(")") catch continue;
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

pub fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
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
        .TypeArray => if (inst.words.len > 2) try commonEmitOneStructForwardDecl(ctx, names, inst.words[2], w, alloc, emitted, emitted_names, type_fn, member_fn),
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
                if (ld.op == .Constant and ld.words.len > 3) {
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
            if (ld.op == .Constant and ld.words.len > 3) {
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
