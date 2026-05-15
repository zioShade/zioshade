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

pub const ParsedModule = struct {
    instructions: []const Instruction,
    id_defs: []const ?usize,
    entry_point_id: ?u32 = null,
    execution_model: spirv.ExecutionModel = .Fragment,
    local_size: [3]u32 = [3]u32{ 1, 1, 1 },

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
        }
    }

    return module;
}

pub fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch (op) {
        .TypeVoid, .TypeBool, .TypeInt, .TypeFloat, .TypeVector, .TypeMatrix,
        .TypeImage, .TypeSampler, .TypeSampledImage, .TypeArray, .TypeRuntimeArray,
        .TypeStruct, .TypePointer, .TypeFunction, .TypeForwardPointer,
        .TypeAccelerationStructureKHR, .TypeRayQueryKHR, .TypeTensorARM,
        => if (words.len > 1) words[1] else null,

        .ConstantTrue, .ConstantFalse, .Constant, .ConstantComposite,
        .SpecConstant, .Undef,
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
        .ImageSampleDrefImplicitLod, .ImageSampleDrefExplicitLod,
        .ImageSampleProjImplicitLod, .ImageSampleProjExplicitLod,
        .ImageDrefGather, .ImageQueryLod, .ImageQueryLevels, .ImageQuerySamples,
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
                    const scalar_type = tryResolveTypeName(module, ti.words[2]);
                    const count = ti.words[3];
                    var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                    defer buf.deinit(alloc);
                    buf.writer(alloc).print("{s}{d}(", .{scalar_type, count}) catch continue;
                    for (inst.words[3..], 0..) |comp_id, i| {
                        if (i > 0) buf.writer(alloc).writeAll(", ") catch continue;
                        const comp_name = names.get(comp_id) orelse "0.0";
                        buf.writer(alloc).writeAll(comp_name) catch continue;
                    }
                    buf.writer(alloc).writeAll(")") catch continue;
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
