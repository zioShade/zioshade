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

const log = std.log.scoped(.spirv_to_hlsl);

// ---------------------------------------------------------------------------
// SPIR-V Binary Parser
// ---------------------------------------------------------------------------

const LoopInfo = struct { merge: u32, cont: u32 };

const Instruction = struct {
    op: spirv.Op,
    words: []const u32,
};

const ParsedModule = struct {
    instructions: []const Instruction,
    id_defs: []const ?usize,
    entry_point_id: ?u32 = null,
    execution_model: spirv.ExecutionModel = .Fragment,
    local_size: [3]u32 = [3]u32{ 1, 1, 1 },

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
        }
    }

    return module;
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
        .SpecConstant, .Undef,
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

pub const HlslCompileOptions = struct {
    binding_shift: i32 = 0,
    shader_model: u32 = 60,
};

pub fn spirvToHLSL(
    alloc: std.mem.Allocator,
    spirv_words: []const u32,
    options: HlslCompileOptions,
) ![]const u8 {
    var module = try parseModule(alloc, spirv_words);
    defer module.deinit(alloc);

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

    // Emit cbuffers
    for (cbuffers.items) |cb| {
        var binding: i32 = @intCast(cb.binding);
        binding += options.binding_shift;
        if (binding < 0) binding = 0;
        try w.print("cbuffer {s} : register(b{d})\n{{\n", .{ cb.name, binding });
        try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa);
        try w.writeAll("};\n\n");
    }

    // Emit textures
    for (textures.items) |tex| {
        try w.print("{s} {s} : register(t{d});\n", .{ tex.hlsl_type, tex.name, tex.binding });
        try w.print("SamplerState {s}_sampler : register(s{d});\n", .{ tex.name, tex.binding });
    }
    if (textures.items.len > 0) try w.writeAll("\n");

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

    // Emit specialization constants as HLSL static const declarations
    for (module.instructions) |inst| {
        if (inst.op == .SpecConstant and inst.words.len > 3) {
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
            if (spec_id) |sid| {
                const default_val = if (inst.words.len > 3) inst.words[3] else 0;
                if (std.mem.eql(u8, type_str, "float")) {
                    const fv: f32 = @bitCast(default_val);
                    try w.print("// specialization constant {d}\nstatic const {s} {s} = {d};\n", .{sid, type_str, name, fv});
                } else {
                    try w.print("// specialization constant {d}\nstatic const {s} {s} = {d};\n", .{sid, type_str, name, default_val});
                }
            }
        }
    }
    try w.writeAll("\n");

    // Emit non-entry functions first (user-defined functions)
    for (func_ids.items) |fid| {
        if (fid == entry_id) continue; // emit entry last
        try emitFunction(&module, &names, &decorations, fid, w, aa, false, &out_param_info);
    }

    // Emit entry function last
    try emitFunction(&module, &names, &decorations, entry_id, w, aa, true, &out_param_info);
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
};

const TextureDecl = struct {
    name: []const u8,
    binding: u32,
    hlsl_type: []const u8,
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

fn getDecorationValue(decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decorations.get(id) orelse return null;
    for (list.items) |entry| {
        if (entry.decoration == dec and entry.extra.len > 0) return entry.extra[0];
    }
    return null;
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
                const hlsl_type = switch (pointee_inst.op) {
                    .TypeSampledImage => hlslTextureTypeFromImage(module, pointee_inst.words[2]),
                    .TypeImage => hlslTextureTypeFromImage(module, pointee_type),
                    .TypeSampler => continue, // samplers paired with textures
                    else => continue,
                };
                textures.append(alloc, .{
                    .name = name,
                    .binding = binding,
                    .hlsl_type = hlsl_type,
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

    // MS textures
    if (is_ms) {
        return switch (dim) {
            .Dim2D => if (is_arrayed) "Texture2DMSArray" else "Texture2DMS",
            else => "Texture2DMS",
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
        .Dim1D => if (is_arrayed) "Texture1DArray" else "Texture1D",
        .Dim2D => if (is_arrayed) "Texture2DArray" else "Texture2D",
        .DimCube => if (is_arrayed) "TextureCubeArray" else "TextureCube",
        .Dim3D => "Texture3D",
        .DimBuffer => "Buffer",
        else => "Texture2D",
    };
}

// ---------------------------------------------------------------------------
// Type resolution
// ---------------------------------------------------------------------------

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
        .TypeStruct => return names.get(type_id) orelse "Struct",
        else => return "float4",
    }
}

// ---------------------------------------------------------------------------
// Struct member emission
// ---------------------------------------------------------------------------

fn emitStructMembers(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_type_id: u32, cbuffer_name: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const inst = getDef(module, struct_type_id) orelse return;
    if (inst.op != .TypeStruct) return;

    for (inst.words[2..], 0..) |member_type_id, member_idx| {
        const member_type = try hlslType(module, member_type_id, names, alloc);

        // Check for array
        const mt_inst = getDef(module, member_type_id);
        if (mt_inst) |mi| {
            if (mi.op == .TypeArray and mi.words.len > 3) {
                const elem_type = try hlslType(module, mi.words[2], names, alloc);
                const len_id = mi.words[3];
                const len_inst = getDef(module, len_id);
                const len_val: u32 = if (len_inst) |li| li.words[3] else 1;
                try w.print("    {s} {s}_m{d}[{d}];\n", .{ elem_type, cbuffer_name, member_idx, len_val });
                continue;
            }
        }
        try w.print("    {s} {s}_m{d};\n", .{ member_type, cbuffer_name, member_idx });
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

fn emitFunction(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    is_entry: bool,
    out_param_info: *const std.AutoHashMap(u32, std.ArrayList(usize)),
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
    if (is_fragment) {
        for (module.instructions) |inst| {
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
    if (is_compute or is_task) {
        try w.print("[numthreads({d}, {d}, {d})]\n", .{
            module.local_size[0],
            module.local_size[1],
            module.local_size[2],
        });
    }
    if (is_mesh) {
        try w.print("[numthreads({d}, {d}, {d})]\n", .{
            module.local_size[0],
            module.local_size[1],
            module.local_size[2],
        });
        // TODO: emit [OutputTopology("triangle")] and mesh<> signature
        // For now, emit as compute-like
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
    if (is_fragment) {
        try w.writeAll("float4 main(");
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
                is_out_param = true;
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

    // Add input variables as parameters for fragment entry function
    if (is_fragment) {
        for (input_var_ids.items, 0..) |ivid, i| {
            if (param_ids.items.len > 0 or i > 0) try w.writeAll(", ");
            const iv_inst = getDef(module, ivid) orelse continue;
            const iv_name = names.get(ivid) orelse "input_var";
            const iv_type = try hlslType(module, iv_inst.words[1], names, alloc);
            const builtin = getDecorationValue(decorations, ivid, .built_in);
            if (builtin) |b| {
                const semantic = builtInToSemantic(b);
                try w.print("{s} {s} : {s}", .{ iv_type, iv_name, semantic });
            } else {
                const loc = getDecorationValue(decorations, ivid, .location);
                if (loc) |l| {
                    try w.print("{s} {s} : TEXCOORD{d}", .{ iv_type, iv_name, l });
                } else {
                    try w.print("{s} {s}", .{ iv_type, iv_name });
                }
            }
        }
    }

    if (is_fragment) try w.writeAll(") : SV_Target\n{\n") else try w.writeAll(")\n{\n");

    // Declare output variable as local in fragment entry
    if (is_fragment and output_var_id != null) {
        const out_var_inst = getDef(module, output_var_id.?);
        if (out_var_inst) |ovi| {
            const out_type = try hlslType(module, ovi.words[1], names, alloc);
            const out_name = names.get(output_var_id.?) orelse "_fragColor";
            try w.print("    {s} {s};\n", .{ out_type, out_name });
        }
    }

    // Emit body
    try emitBody(module, names, decorations, func_idx, w, alloc, is_fragment, output_var_id);

    // Return output var for fragment
    if (is_fragment and output_var_id != null) {
        const out_name = names.get(output_var_id.?) orelse "_out";
        try w.print("    return {s};\n", .{out_name});
    }

    try w.writeAll("}\n");
}

fn builtInToSemantic(b: u32) []const u8 {
    const bi: spirv.BuiltIn = @enumFromInt(b);
    return switch (bi) {
        .frag_coord => "SV_Position",
        .front_facing => "SV_IsFrontFace",
        .layer => "SV_RenderTargetArrayIndex",
        .view_index => "SV_ViewID",
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

    // Structured emission
    idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .FunctionParameter or inst.op == .Label or
            inst.op == .SelectionMerge or inst.op == .Branch) continue;

        // Handle LoopMerge: emit while(true) { condition; if(!cond) break; body; }
        if (inst.op == .LoopMerge and inst.words.len >= 3) {
            const merge_lbl = inst.words[1];
            const cont_lbl = inst.words[2];
            idx = try emitWhileLoopHLSL(module, names, decorations, idx, merge_lbl, cont_lbl, &label_map, &bc_merge_map, &loop_merge_map, w, alloc, is_fragment, output_var_id);
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
                idx = try emitBlock(module, names, decorations, true_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, output_var_id, "    ");
                if (has_else) {
                    try w.writeAll("    } else {\n");
                    idx = try emitBlock(module, names, decorations, false_label.?, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                // Advance to merge label
                if (label_map.get(ml)) |merge_idx| {
                    idx = merge_idx; // loop will increment
                }
            } else {
                // No merge info — just emit the condition
                try w.print("    if ({s}) {{ /* TODO: no merge info */ }}\n", .{cond_name});
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
                    _ = try emitBlock(module, names, decorations, default_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, output_var_id, "    ");
                }
                // Emit case labels (word 3+: pairs of literal, target)
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const case_val = inst.words[wi];
                    const target_label = inst.words[wi + 1];
                    if (target_label == ml) continue; // skip branches to merge
                    try w.print("    case {d}:\n", .{case_val});
                    _ = try emitBlock(module, names, decorations, target_label, ml, &label_map, &bc_merge_map, w, alloc, is_fragment, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                // Advance to merge label
                if (label_map.get(ml)) |merge_idx| {
                    idx = merge_idx;
                }
            } else {
                try w.print("    // switch ({s}) {{ TODO: no merge info }}\n", .{selector_name});
            }
            continue;
        }

        try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, output_var_id);
    }
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
    w: anytype,
    alloc: std.mem.Allocator,
    is_fragment: bool,
    output_var_id: ?u32,
) !usize {
    // Two patterns after LoopMerge:
    // Pattern A: LoopMerge; Branch cond_label; ...; BranchConditional cond, body, merge
    // Pattern B: LoopMerge; BranchConditional cond, body, merge (merged condition)

    var cond_name: []const u8 = "true";
    var body_lbl: u32 = 0;
    var bc_idx: usize = loop_idx + 1;
    var cond_start: ?usize = null; // start of condition instructions (for pattern A)
    var cond_end: usize = loop_idx + 1; // end of condition instructions

    if (loop_idx + 1 >= module.instructions.len) {
        if (label_map.get(merge_lbl)) |mi| return mi;
        return loop_idx + 1;
    }

    const next_inst = module.instructions[loop_idx + 1];
    if (next_inst.op == .Branch and next_inst.words.len >= 2) {
        // Pattern A: separate condition block
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

    // Emit: while (true) {
    try w.writeAll("    while (true)\n    {\n");

    // Emit condition block instructions (for pattern A)
    if (cond_start) |cs| {
        if (cs < cond_end) {
            var ci: usize = cs;
            while (ci < cond_end) : (ci += 1) {
                const cinst = module.instructions[ci];
                if (cinst.op == .Label or cinst.op == .Branch or cinst.op == .SelectionMerge or cinst.op == .LoopMerge) continue;
                try emitInstruction(module, names, decorations, cinst, w, alloc, is_fragment, output_var_id);
            }
        }
    }

    // Emit: if (!(condition)) break;
    try w.print("        if (!({s})) break;\n", .{cond_name});

    // Emit body block
    const body_idx = label_map.get(body_lbl) orelse module.instructions.len;
    if (body_idx < module.instructions.len) {
        var bi: usize = body_idx + 1;
        while (bi < module.instructions.len) : (bi += 1) {
            const binst = module.instructions[bi];
            if (binst.op == .FunctionEnd) break;
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
                    bi = try emitWhileLoopHLSL(module, names, decorations, bi, nmerge, ncont, label_map, bc_merge_map, loop_merge_map, w, alloc, is_fragment, output_var_id);
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
                if (nml) |nmv| {
                    const nhe = nfl != null and nfl.? != nmv;
                    try w.print("        if ({s})\n        {{\n", .{ncn});
                    bi = try emitBlock(module, names, decorations, ntl, nmv, label_map, bc_merge_map, w, alloc, is_fragment, output_var_id, "        ");
                    if (nhe) {
                        try w.writeAll("        } else {\n");
                        bi = try emitBlock(module, names, decorations, nfl.?, nmv, label_map, bc_merge_map, w, alloc, is_fragment, output_var_id, "        ");
                    }
                    try w.writeAll("        }\n");
                    if (label_map.get(nmv)) |nmi| {
                        bi = nmi;
                    }
                }
                continue;
            }
            try emitInstruction(module, names, decorations, binst, w, alloc, is_fragment, output_var_id);
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
        if (inst.op == .Branch) continue; // branch to somewhere else (e.g., loop back-edge)

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
                i = try emitBlock(module, names, decorations, true_lbl, nm, label_map, bc_merge_map, w, alloc, is_fragment, output_var_id, indent);
                if (has_else) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    i = try emitBlock(module, names, decorations, false_lbl.?, nm, label_map, bc_merge_map, w, alloc, is_fragment, output_var_id, indent);
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
        try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, output_var_id);
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
    output_var_id: ?u32,
) !void {
    _ = decorations;

    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            // Output variables in fragment entry: declare as local (will be returned)
            if (sc == .Output and is_fragment) {
                const result_id = inst.words[2];
                const type_name = try hlslType(module, inst.words[1], names, alloc);
                try w.print("    {s} {s};\n", .{ type_name, names.get(result_id) orelse "var" });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant) return;
            const result_id = inst.words[2];
            const type_name = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s};\n", .{ type_name, names.get(result_id) orelse "var" });
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
                }
            }

            if (is_output_load) {
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

        .CopyObject => {
            // OpCopyObject: just alias the source ID to the result ID
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
            const expr = try buildAccessExpr(module, names, base_id, inst.words[4..], alloc);
            // Replace the name
            if (try names.fetchPut(result_id, expr)) |old| alloc.free(old.value);
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
        .FOrdEqual, .IEqual => try emitBinOp(module, names, inst, "==", w, alloc),
        .FOrdNotEqual, .INotEqual => try emitBinOp(module, names, inst, "!=", w, alloc),
        .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(module, names, inst, "<", w, alloc),
        .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(module, names, inst, ">", w, alloc),
        .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(module, names, inst, "<=", w, alloc),
        .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(module, names, inst, ">=", w, alloc),

        .LogicalOr => try emitBinOp(module, names, inst, "||", w, alloc),
        .LogicalAnd => try emitBinOp(module, names, inst, "&&", w, alloc),
        .LogicalNot => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{ rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },

        .Select => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{
                rt, names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "c",
                names.get(inst.words[4]) orelse "t",
                names.get(inst.words[5]) orelse "f",
            });
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
            const parent_type = getTypeOf(module, inst.words[3]);
            const is_vec = if (parent_type) |pt| blk: {
                const pt_inst = getDef(module, pt);
                break :blk pt_inst != null and pt_inst.?.op == .TypeVector;
            } else false;

            for (inst.words[4..]) |index| {
                if (is_vec) {
                    try w.writeAll(switch (index) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                } else {
                    try w.print("._m{d}", .{index});
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
            const parent_type = getTypeOf(module, inst.words[4]);
            const is_vec = if (parent_type) |pt| blk: {
                const pt_inst = getDef(module, pt);
                break :blk pt_inst != null and pt_inst.?.op == .TypeVector;
            } else false;
            try w.print("    {s}", .{rname});
            for (inst.words[5..]) |index| {
                if (is_vec) {
                    try w.writeAll(switch (index) {
                        0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x",
                    });
                } else {
                    try w.print("._m{d}", .{index});
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
            // Projected sample: divide xy by w
            try w.print("    {s} {s} = {s}.Sample({s}, {s}.xy / {s}.w);\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord,
            });
        },
        .ImageSampleProjDrefImplicitLod => {
            // Projected shadow: SampleCmp with manual projection
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.SampleCmp({s}, {s}.xy / {s}.w, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, dref,
            });
        },
        .ImageSampleProjDrefExplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
            const parts = splitPair(si);
            try w.print("    {s} {s} = {s}.SampleCmpLevelZero({s}, {s}.xy / {s}.w, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, coord, dref,
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
            try w.print("    {s} {s} = {s}.Load({s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0",
            });
        },
        .ImageGather => {
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
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const img_name = names.get(inst.words[3]) orelse "tex";
            const lod = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
            // Strip _sampler suffix to get texture name
            var tex_name: []const u8 = img_name;
            if (std.mem.endsWith(u8, img_name, "_sampler")) {
                tex_name = img_name[0..img_name.len - "_sampler".len];
            }
            try w.print("    {s} {s} = {s}.GetDimensions({s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", tex_name, lod,
            });
        },
        .ImageQuerySize => {
            // OpImageQuerySize: result_type, result, image (no lod)
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const img_name = names.get(inst.words[3]) orelse "tex";
            var tex_name: []const u8 = img_name;
            if (std.mem.endsWith(u8, img_name, "_sampler")) {
                tex_name = img_name[0..img_name.len - "_sampler".len];
            }
            try w.print("    {s} {s} = {s}.GetDimensions(0);\n", .{
                rt, names.get(inst.words[2]) orelse "v", tex_name,
            });
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
            const rtt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = clock();\n", .{ rtt, names.get(inst.words[2]) orelse "t" });
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
            // Skip bare return in fragment entry — we emit the output return at function end
            if (is_fragment and output_var_id != null) {} else {
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

fn splitPair(pair: []const u8) [2][]const u8 {
    if (std.mem.indexOfScalar(u8, pair, ',')) |comma| {
        return .{ pair[0..comma], pair[comma + 1 ..] };
    }
    return .{ pair, pair };
}

fn writeResolvePointer(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, w: anytype) !void {
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

fn writeAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) { try w.writeAll(base_name); return; }
    const base_is_cb = isUniformVariable(module, base_id);
    const cb_prefix = if (base_is_cb) names.get(base_id) orelse "Globals" else "";
    if (!base_is_cb) try w.writeAll(base_name);
    var cur_type: ?u32 = resolvePointeeType(module, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(module, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(module, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else if (base_is_cb) {
                    try w.print("{s}_m{d}", .{cb_prefix, val});
                } else {
                    try w.print("[{d}]", .{val});
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
            } else { try w.print("[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { try w.print("[{s}]", .{names.get(index_id) orelse "i"}); }
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
    const base_name = names.get(base_id) orelse "base";

    if (indices.len == 0) return try alloc.dupe(u8, base_name);

    // Check if base is a cbuffer/UBO variable (Uniform storage class)
    // In HLSL, cbuffer members are accessed using cbufferName_mN prefix
    const base_is_cbuffer = isUniformVariable(module, base_id);
    const cbuffer_prefix = if (base_is_cbuffer) names.get(base_id) orelse "Globals" else "";

    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    if (!base_is_cbuffer) {
        try buf.appendSlice(alloc, base_name);
    }

    // Walk the type chain starting from the base pointer's pointee type
    var current_type_id: ?u32 = resolvePointeeType(module, base_id);

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
                } else if (base_is_cbuffer) {
                    // Cbuffer members use cbufferName_mN prefix for uniqueness
                    try buf.print(alloc, "{s}_m{d}", .{cbuffer_prefix, val});
                } else {
                    try buf.print(alloc, "._m{d}", .{val});
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
            }
        } else {
            try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"});
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Check if an ID is a Uniform storage class variable (cbuffer/UBO).
fn isUniformVariable(module: *const ParsedModule, id: u32) bool {
    const inst = getDef(module, id) orelse return false;
    if (inst.op == .Variable and inst.words.len >= 4) {
        const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        return sc == .Uniform;
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
            // Fallback for instruction IDs that don't match our enum values.
            // Some codegen paths hardcode correct GLSLstd450 values while our enum has different values.
            const val = @intFromEnum(func);
            break :blk switch (val) {
                // Correct GLSLstd450 instruction IDs (per SPIR-V spec)
                1 => "round",
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
                38 => "max",       // FMax
                39 => "min",       // SMin
                40 => "max",       // SMax
                41 => "min",       // UMin
                42 => "max",       // UMax
                43 => "clamp",     // FClamp
                44 => "clamp",     // SClamp
                45 => "clamp",     // UClamp
                46 => "lerp",      // FMix / mix
                48 => "step",
                49 => "smoothstep",
                50 => "fma",       // FMA (fused multiply-add)
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


