// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → HLSL cross-compiler backend.
//!
//! Parses a SPIR-V binary into an instruction stream, resolves types/decorations,
//! and emits HLSL Shader Model 6.0 source code.
//!
//! Currently targeting fragment shaders for wintty integration.

const std = @import("std");
const spirv = @import("spirv.zig");

const log = std.log.scoped(.spirv_to_hlsl);

// ---------------------------------------------------------------------------
// SPIR-V Binary Parser
// ---------------------------------------------------------------------------

const Instruction = struct {
    op: spirv.Op,
    words: []const u32,
};

const ParsedModule = struct {
    instructions: []const Instruction,
    id_defs: std.AutoHashMapUnmanaged(u32, usize),
    entry_point_id: ?u32 = null,
    execution_model: spirv.ExecutionModel = .Fragment,

    pub fn deinit(self: *ParsedModule, alloc: std.mem.Allocator) void {
        self.id_defs.deinit(alloc);
    }
};

fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;

    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch
        return error.OutOfMemory;
    errdefer instructions.deinit(alloc);

    var id_defs = std.AutoHashMapUnmanaged(u32, usize){};
    errdefer id_defs.deinit(alloc);

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
            id_defs.put(alloc, id, instructions.items.len) catch
                return error.OutOfMemory;
        }

        instructions.append(alloc, .{ .op = op, .words = inst_words }) catch
            return error.OutOfMemory;

        i += word_count;
    }

    var module = ParsedModule{
        .instructions = instructions.items,
        .id_defs = id_defs,
    };

    // Extract entry point
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) {
            if (module.entry_point_id == null) {
                module.execution_model = @enumFromInt(inst.words[1]);
                module.entry_point_id = inst.words[2];
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
        .Load, .AccessChain, .CompositeConstruct, .CompositeExtract,
        .VectorShuffle, .SampledImage, .ImageSampleImplicitLod,
        .ImageSampleExplicitLod, .ImageFetch, .ImageGather,
        .ImageQuerySizeLod, .ImageQuerySize,
        .ImageTexelPointer, .FunctionCall,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast,
        .SNegate, .FNegate,
        .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul,
        .FMod, .UDiv, .SDiv, .FDiv, .UMod, .SRem, .FRem,
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
        => if (words.len > 2) words[2] else null,

        else => null,
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    const idx = module.id_defs.get(id) orelse return null;
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
    binding_shift: i32 = -1,
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

    var names = std.AutoHashMap(u32, []const u8).init(alloc);
    defer {
        var nit = names.iterator();
        while (nit.next()) |entry| alloc.free(entry.value_ptr.*);
        names.deinit();
    }

    var decorations = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(alloc);
    defer {
        var dit = decorations.iterator();
        while (dit.next()) |entry| entry.value_ptr.deinit(alloc);
        decorations.deinit();
    }

    // Phase 1: collect names, decorations
    collectNames(alloc, &module, &names);
    try collectDecorations(alloc, &module, &decorations);

    // Phase 2: collect resources
    var cbuffers = std.ArrayList(CbufferDecl).initCapacity(alloc, 0) catch return error.OutOfMemory;
    defer cbuffers.deinit(alloc);
    var textures = std.ArrayList(TextureDecl).initCapacity(alloc, 0) catch return error.OutOfMemory;
    defer textures.deinit(alloc);

    collectResources(&module, &names, &decorations, &cbuffers, &textures, alloc);

    // Phase 3: emit HLSL
    var output = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer output.deinit(alloc);
    const w = output.writer(alloc);

    try w.writeAll("// Generated by glslpp SPIR-V -> HLSL cross-compiler\n\n");

    // Emit cbuffers
    for (cbuffers.items) |cb| {
        var binding: i32 = @intCast(cb.binding);
        binding += options.binding_shift;
        if (binding < 0) binding = 0;
        try w.print("cbuffer {s} : register(b{d})\n{{\n", .{ cb.name, binding });
        try emitStructMembers(&module, &names, cb.type_id, w, alloc);
        try w.writeAll("};\n\n");
    }

    // Emit textures
    for (textures.items) |tex| {
        try w.print("{s} {s} : register(t{d});\n", .{ tex.hlsl_type, tex.name, tex.binding });
        try w.print("SamplerState {s}_sampler : register(s{d});\n", .{ tex.name, tex.binding });
    }
    if (textures.items.len > 0) try w.writeAll("\n");

    // Emit entry function
    try emitFunction(&module, &names, &decorations, entry_id, w, alloc);

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
                const hlsl_type: []const u8 = switch (pointee_inst.op) {
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

    return switch (dim) {
        .Dim1D => "Texture1D",
        .Dim2D => "Texture2D",
        .Dim3D => "Texture3D",
        .DimCube => "TextureCube",
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
        .TypeFloat => return "float",
        .TypeVector => {
            const scalar = try hlslType(module, inst.words[2], names, alloc);
            return std.fmt.allocPrint(alloc, "{s}{d}", .{ scalar, inst.words[3] });
        },
        .TypeMatrix => {
            const col_type = getDef(module, inst.words[2]);
            const cols = inst.words[3];
            const rows: u32 = if (col_type) |ct| ct.words[3] else cols;
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

fn emitStructMembers(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_type_id: u32, w: anytype, alloc: std.mem.Allocator) !void {
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
                try w.print("    {s} _m{d}[{d}];\n", .{ elem_type, member_idx, len_val });
                continue;
            }
        }
        try w.print("    {s} _m{d};\n", .{ member_type, member_idx });
    }
}

// ---------------------------------------------------------------------------
// Function emission
// ---------------------------------------------------------------------------

fn emitFunction(
    module: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    entry_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
) !void {
    const func_inst = getDef(module, entry_id) orelse return;
    if (func_inst.op != .Function or func_inst.words.len < 5) return;

    const func_type_id = func_inst.words[4];
    const func_type_inst = getDef(module, func_type_id) orelse return;
    const return_type_id = func_type_inst.words[2];
    const return_type = try hlslType(module, return_type_id, names, alloc);
    const is_fragment = module.execution_model == .Fragment;

    // Find output variable for fragment shader
    var output_var_id: ?u32 = null;
    if (is_fragment) {
        for (module.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) {
                    output_var_id = inst.words[2];
                    break;
                }
            }
        }
    }

    // Collect function parameters
    const func_idx = module.id_defs.get(entry_id) orelse return;
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

    // Emit signature
    if (is_fragment) {
        try w.writeAll("float4 main(");
    } else {
        try w.print("{s} main(", .{return_type});
    }

    // Emit parameters with semantics
    for (param_ids.items, 0..) |pid, i| {
        if (i > 0) try w.writeAll(", ");
        const p_inst = getDef(module, pid).?;
        const p_type = try hlslType(module, p_inst.words[1], names, alloc);
        const p_name = names.get(pid) orelse "p";

        const builtin = getDecorationValue(decorations, pid, .built_in);
        const loc = getDecorationValue(decorations, pid, .location);

        if (builtin) |b| {
            const semantic = builtInToSemantic(b);
            try w.print("{s} {s} : {s}", .{ p_type, p_name, semantic });
        } else if (loc) |l| {
            if (l == 0 and i == 0)
                try w.print("{s} {s} : SV_Position", .{ p_type, p_name })
            else
                try w.print("{s} {s} : TEXCOORD{d}", .{ p_type, p_name, l });
        } else {
            try w.print("{s} {s}", .{ p_type, p_name });
        }
    }

    if (is_fragment) try w.writeAll(") : SV_Target\n{\n") else try w.writeAll(")\n{\n");

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
    var idx = func_idx + 1;
    while (idx < module.instructions.len) : (idx += 1) {
        const inst = module.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .FunctionParameter or inst.op == .Label) continue;

        try emitInstruction(module, names, decorations, inst, w, alloc, is_fragment, output_var_id);
    }
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
    _ = is_fragment;
    _ = output_var_id;

    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant) return;
            const result_id = inst.words[2];
            const type_name = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s};\n", .{ type_name, names.get(result_id) orelse "var" });
        },

        .Load => {
            const result_type = try hlslType(module, inst.words[1], names, alloc);
            const result_name = names.get(inst.words[2]) orelse "v";
            const ptr_id = inst.words[3];
            const ptr_expr = try resolvePointer(module, names, ptr_id, alloc);
            try w.print("    {s} {s} = {s};\n", .{ result_type, result_name, ptr_expr });
        },

        .Store => {
            if (inst.words.len < 3) return;
            const ptr_expr = try resolvePointer(module, names, inst.words[1], alloc);
            const obj_name = names.get(inst.words[2]) orelse "0";
            try w.print("    {s} = {s};\n", .{ ptr_expr, obj_name });
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
        .FMod, .UMod, .SRem, .FRem => try emitBinOp(module, names, inst, "%", w, alloc),

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

        // Conversions
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU => {
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
        .Fwidth, .FwidthFine, .FwidthCoarse => try emitCall(module, names, inst, "fwidth", w, alloc),

        .All => try emitCall(module, names, inst, "all", w, alloc),
        .Any => try emitCall(module, names, inst, "any", w, alloc),

        // GLSLstd450
        .ExtInst => {
            if (inst.words.len < 5) return;
            const instruction = inst.words[4];
            try emitStd450(module, names, inst, instruction, w, alloc);
        },

        // Texture ops
        .SampledImage => {
            const result_id = inst.words[2];
            const img_name = names.get(inst.words[3]) orelse "tex";
            const pair = try std.fmt.allocPrint(alloc, "{s},{s}_sampler", .{ img_name, img_name });
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
        .ImageSampleExplicitLod => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex,tex_sampler";
            const coord = names.get(inst.words[4]) orelse "uv";
            const parts = splitPair(si);
            // Find Lod in image operands
            var lod: []const u8 = "0";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                // Bit 0 = Bias, Bit 1 = Lod, Bit 2 = Grad, Bit 3 = ConstOffset, Bit 4 = Offset
                if (mask & 0x1 != 0) off += 1; // skip Bias
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    lod = names.get(inst.words[off]) orelse "0";
                }
            }
            try w.print("    {s} {s} = {s}.SampleLevel({s}, {s}, {s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", parts[0], parts[1], coord, lod,
            });
        },
        .ImageFetch => {
            const rt = try hlslType(module, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}.Load({s});\n", .{
                rt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0",
            });
        },

        // Control flow
        .Kill => try w.writeAll("    discard;\n"),
        .Return => try w.writeAll("    return;\n"),
        .ReturnValue => {
            try w.print("    return {s};\n", .{names.get(inst.words[1]) orelse "0"});
        },
        .Branch => {},
        .BranchConditional => {},
        .SelectionMerge => {},
        .LoopMerge => {},
        .Label => {},
        .ControlBarrier => try w.writeAll("    GroupMemoryBarrierWithGroupSync();\n"),
        .MemoryBarrier => try w.writeAll("    DeviceMemoryBarrier();\n"),

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

fn resolvePointer(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(module, ptr_id) orelse return names.get(ptr_id) orelse "var";
    if (inst.op == .AccessChain) {
        return try buildAccessExpr(module, names, inst.words[3], inst.words[4..], alloc);
    }
    return names.get(ptr_id) orelse "var";
}

fn buildAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";

    if (indices.len == 0) return try alloc.dupe(u8, base_name);

    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    try buf.writer(alloc).writeAll(base_name);

    for (indices) |index_id| {
        const idx_inst = getDef(module, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                // Check if base is a vector type (use swizzle) or struct (use _mN)
                try buf.writer(alloc).print("._m{d}", .{val});
            } else {
                try buf.writer(alloc).print("[{s}]", .{names.get(index_id) orelse "i"});
            }
        } else {
            try buf.writer(alloc).print("[{s}]", .{names.get(index_id) orelse "i"});
        }
    }

    return buf.toOwnedSlice(alloc);
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
        .Reflect => "reflect",
        .Refract => "refract",
        .FaceForward => "faceforward",
        .Determinant => "determinant",
        .MatrixInverse => "inverse",
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------


