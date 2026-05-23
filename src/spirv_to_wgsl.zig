// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → WGSL (WebGPU Shading Language) cross-compiler backend.

const std = @import("std");
const spirv = @import("spirv.zig");
const common = @import("spirv_cross_common.zig");

const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = common.DecorationEntry;

pub const WgslCompileOptions = struct {};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDef(module: *const ParsedModule, id: u32) ?Instruction {
    return common.getDef(module, id);
}

fn getTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    return common.getTypeOf(module, id);
}

fn getMemberName(module: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    return common.commonGetMemberName(module.instructions, struct_id, member_idx, buf, "_");
}

fn getArraySuffix(module: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    return common.commonGetArraySuffix(module.instructions, module.id_defs, ptr_type_id, false);
}

fn emitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitStructForwardDecls(module, names, root_type_id, w, alloc, emitted, emitted_names, wgslType, getMemberName);
}

fn emitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    return common.commonEmitOneStructForwardDecl(module, names, type_id, w, alloc, emitted, emitted_names, wgslType, getMemberName);
}

// ---------------------------------------------------------------------------
// WGSL type resolution
// ---------------------------------------------------------------------------

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
            // Check if multisampled (words[6])
            const is_ms = if (inst.words.len > 6) inst.words[6] == 1 else false;
            if (is_ms) {
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
}

// ---------------------------------------------------------------------------
// Access expression builder
// ---------------------------------------------------------------------------

fn buildAccessExpr(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
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

/// Resolve the value type of an ID by tracing its defining instruction.
fn resolveTypeOf(module: *const ParsedModule, id: u32) ?u32 {
    const inst = common.getDef(module, id) orelse return null;
    switch (inst.op) {
        .Variable => {
            if (inst.words.len > 1) return common.resolvePointeeType(module, inst.words[1]);
            return null;
        },
        .Load, .CopyObject, .CompositeConstruct, .CompositeInsert,
        .FunctionCall, .Phi, .Select, .CopyLogical,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast,
        .VectorShuffle, .CompositeExtract, .VectorTimesScalar,
        .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector,
        .MatrixTimesMatrix, .OuterProduct, .ImageSampleImplicitLod,
        .ImageSampleExplicitLod, .ImageFetch, .ImageRead,
        .FNegate, .SNegate, .Not, .LogicalNot,
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
    _ = options;
    var module = try common.parseModule(alloc, spirv_words);
    defer module.deinit(alloc);

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
            if (std.mem.startsWith(u8, name, "float2(")) {
                const rest = name["float2".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec2f{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
            } else if (std.mem.startsWith(u8, name, "float3(")) {
                const rest = name["float3".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec3f{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
            } else if (std.mem.startsWith(u8, name, "float4(")) {
                const rest = name["float4".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec4f{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
            } else if (std.mem.startsWith(u8, name, "int2(")) {
                const rest = name["int2".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec2i{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
            } else if (std.mem.startsWith(u8, name, "int3(")) {
                const rest = name["int3".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec3i{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
            } else if (std.mem.startsWith(u8, name, "int4(")) {
                const rest = name["int4".len..];
                const new_name = std.fmt.allocPrint(alloc, "vec4i{s}", .{rest}) catch continue;
                replacements.append(alloc, .{ .key = e.key_ptr.*, .val = new_name }) catch continue;
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

    // Find entry point and function
    var entry_func_idx: ?usize = null;
    var output_var_id: ?u32 = null;
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
                        if (output_var_id == null) output_var_id = inst.words[2];
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
    var cbuffers = std.ArrayList(struct { name: []const u8, type_id: u32, binding: u32, is_ssbo: bool }).initCapacity(arena, 4) catch return error.OutOfMemory;
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
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .binding = binding * 2 + set, .is_ssbo = is_ssbo });
            },
            .StorageBuffer => {
                const binding = getDecVal(&decorations, result_id, .binding) orelse 0;
                const set = getDecVal(&decorations, result_id, .descriptor_set) orelse 0;
                const name = names.get(result_id) orelse "buffer";
                try cbuffers.append(arena, .{ .name = name, .type_id = pointee_type, .binding = binding * 2 + set, .is_ssbo = true });
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

    // Emit struct forward declarations for types used in cbuffers
    var emitted_structs = std.AutoHashMap(u32, void).init(arena);
    defer emitted_structs.deinit();
    var emitted_names = std.StringHashMap(void).init(arena);
    defer emitted_names.deinit();

    for (cbuffers.items) |cb| {
        try emitStructForwardDecls(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names);
        try emitOneStructForwardDecl(&module, &names, cb.type_id, w, arena, &emitted_structs, &emitted_names);
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
                                try emitOneStructForwardDecl(&module, &names, tid, w, arena, &emitted_structs, &emitted_names);
                            }
                        }
                    }
                }
            }
        }
    }

    // Emit uniform buffers
    for (cbuffers.items) |cb| {
        const group = @divFloor(cb.binding, 2);
        const binding = cb.binding;
        if (cb.is_ssbo) {
            try w.print("@group({d}) @binding({d})\nvar<storage, read_write> {s}: ", .{ group, binding, cb.name });
        } else {
            try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: ", .{ group, binding, cb.name });
        }
        const type_name = blk: {
            // Resolve pointer type to pointee type
            const ptr_inst = getDef(&module, cb.type_id);
            const actual_type = if (ptr_inst) |pi|
                if (pi.op == .TypePointer and pi.words.len > 3) pi.words[3] else cb.type_id
            else cb.type_id;
            break :blk try wgslType(&module, actual_type, &names, arena);
        };
        try w.print("{s};\n\n", .{type_name});
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
                        try emitOneStructForwardDecl(&module, &names, pointee_type, w, arena, &emitted_structs, &emitted_names);
                        try w.print("var<workgroup> {s}: {s};\n\n", .{ var_name, type_name });
                    }
                }
            }
        }
    }

    // Emit textures and samplers
    // Group sampler + texture pairs
    var sampler_names = std.ArrayList(struct { name: []const u8, binding: u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;

    for (textures.items) |tex| {
        const group = @divFloor(tex.binding, 2);
        const binding = tex.binding;
        const tex_type = try wgslType(&module, tex.image_type_id, &names, arena);
        if (tex.is_storage) {
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n\n", .{ group, binding, tex.name, tex_type });
        } else {
            try w.print("@group({d}) @binding({d})\nvar {s}: {s};\n", .{ group, binding, tex.name, tex_type });
            // Emit paired sampler
            const sampler_name = try std.fmt.allocPrint(arena, "{s}_sampler", .{tex.name});
            try sampler_names.append(arena, .{ .name = sampler_name, .binding = tex.binding + 1 });
            try w.print("@group({d}) @binding({d})\nvar {s}: sampler;\n\n", .{ group, binding + 1, sampler_name });
        }
    }

    // Emit non-entry functions first
    var func_ids = std.ArrayList(u32).initCapacity(arena, 8) catch return error.OutOfMemory;
    var func_idx_map = std.AutoHashMap(u32, usize).init(arena);
    for (module.instructions, 0..) |inst, i| {
        if (inst.op == .Function and inst.words.len > 2) {
            func_ids.appendAssumeCapacity(inst.words[2]);
            func_idx_map.put(inst.words[2], i) catch {};
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
        // Parameters (words[3..] of TypeFunction)
        var param_count: usize = 0;
        try w.print("fn {s}(", .{func_name});
        for (ft_inst.?.words[3..], 0..) |param_type_id, pi| {
            if (pi > 0) try w.writeAll(", ");
            const pt = try wgslType(&module, param_type_id, &names, arena);
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
            try w.print("{s}: {s}", .{p_name, pt});
            param_count += 1;
        }
        try w.print(") -> {s} {{\n", .{ret_type});
        try emitBody(&module, &names, &decorations, fidx, w, alloc, arena);
        try w.writeAll("}\n\n");
    }

    // Emit entry function
    const entry_stage: []const u8 = if (is_fragment) "@fragment" else if (is_vertex) "@vertex" else if (is_compute) "@compute" else "@fragment";

    // Build function signature
    try w.print("{s}\nfn main(", .{entry_stage});

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
                .vertex_id => "vertex_id",
                .instance_id => "instance_id",
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
        const ov = output_var_id.?;
        const ptr_inst = getDef(&module, getDef(&module, ov).?.words[1]);
        var actual_type: u32 = undefined;
        if (ptr_inst) |pi| {
            if (pi.op == .TypePointer and pi.words.len > 3) actual_type = pi.words[3] else actual_type = ov;
        } else actual_type = ov;
        const type_name = try wgslType(&module, actual_type, &names, arena);
        try w.print(") -> @location(0) {s} {{\n", .{type_name});
    } else if (is_vertex and output_vars.items.len > 0 and output_var_id != null) {
        // For vertex shaders, use the selected output var (prefers builtin like gl_Position)
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
        try w.writeAll(") {\n");
    }

    // Declare output variable as local
    if ((is_fragment or is_vertex) and output_var_id != null) {
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

    // Emit function body
    try emitBody(&module, &names, &decorations, entry_func_idx.?, w, alloc, arena);

    // Return output var
    if ((is_fragment or is_vertex) and output_var_id != null) {
        const var_name = names.get(output_var_id.?) orelse "out";
        try w.print("    return {s};\n", .{var_name});
    }

    try w.writeAll("}\n");

    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Body emitter
// ---------------------------------------------------------------------------

fn emitBody(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), func_idx: usize, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator) !void {
    _ = decorations;
    // Skip function declaration instructions
    var i: usize = func_idx + 1;
    // Skip FunctionParameter instructions (parameters declared in function signature)
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];
        if (inst.op == .Label) { i += 1; break; }
        if (inst.op == .FunctionParameter) continue;
        break;
    }

    // Emit instructions
    while (i < module.instructions.len) : (i += 1) {
        const inst = module.instructions[i];
        switch (inst.op) {
            .FunctionEnd => return,
            .Label, .Branch, .BranchConditional, .LoopMerge, .SelectionMerge, .Phi => {},

            .Variable => {
                if (inst.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                    if (sc == .Function) {
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const vn = names.get(inst.words[2]) orelse "v";
                        try w.print("    var {s}: {s};\n", .{ vn, rt });
                    } else if (sc == .Private) {
                        const rt = try wgslType(module, inst.words[1], names, arena);
                        const vn = names.get(inst.words[2]) orelse "v";
                        try w.print("    var {s}: {s};\n", .{ vn, rt });
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
                } else {
                    var expr: []const u8 = ptr;
                    var expr_allocated = false;
                    if (ptr_inst) |pi| {
                        if (pi.op == .AccessChain) {
                            expr = try buildAccessExpr(module, names, pi.words[3], pi.words[4..], alloc);
                            expr_allocated = true;
                        }
                    }
                    try w.print("    var {s}: {s} = {s};\n", .{ result_name, rt, expr });
                    if (expr_allocated) alloc.free(expr);
                }
            },

            // Store
            .Store => {
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
                try w.print("    {s} = {s};\n", .{ expr, val });
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
                var parts = std.ArrayList(u8).initCapacity(alloc, 128) catch return;
                defer parts.deinit(alloc);
                for (inst.words[3..], 0..) |comp_id, ci| {
                    if (ci > 0) try parts.appendSlice(alloc, ", ");
                    const comp_name = names.get(comp_id) orelse "0";
                    try parts.appendSlice(alloc, comp_name);
                }
                try w.print("    var {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, parts.items });
            },

            // CompositeExtract
            .CompositeExtract => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const composite = names.get(inst.words[3]) orelse "c";
                // Build type-aware access expression
                var expr = std.ArrayList(u8).initCapacity(alloc, 64) catch return;
                defer expr.deinit(alloc);
                try expr.appendSlice(alloc, composite);
                // Resolve composite type for member name resolution
                var current_type: ?u32 = resolveTypeOf(module, inst.words[3]);
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
                try w.print("    var {s}: {s} = {s};\n", .{ result_name, rt, expr.items });
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
                var swizzle = std.ArrayList(u8).initCapacity(alloc, 16) catch return;
                defer swizzle.deinit(alloc);
                for (inst.words[5..]) |idx| {
                    const src = if (idx < 4) v1 else v2;
                    const comp = idx % 4;
                    if (swizzle.items.len > 0 and std.mem.endsWith(u8, swizzle.items, src)) {
                        try swizzle.append(alloc, switch (comp) { 0 => 'x', 1 => 'y', 2 => 'z', 3 => 'w', else => 'x' });
                    } else {
                        // Different source vector — can't use simple swizzle
                        try swizzle.print(alloc, "{s}[{d}]", .{ src, comp });
                    }
                }
                try w.print("    // shuffle: {s}\n", .{swizzle.items});
                // Simple approach: construct from components
                try w.print("    var {s}: {s} = {s}(", .{ result_name, rt, rt });
                var first = true;
                for (inst.words[5..]) |idx| {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    const src = if (idx < 4) v1 else v2;
                    const comp = idx % 4;
                    const sw = switch (comp) { 0 => ".x", 1 => ".y", 2 => ".z", 3 => ".w", else => ".x" };
                    try w.print("{s}{s}", .{ src, sw });
                }
                try w.writeAll(");\n");
            },

            // Arithmetic
            .FAdd, .IAdd => try emitBinOp(module, names, inst, "+", w, arena),
            .FSub, .ISub => try emitBinOp(module, names, inst, "-", w, arena),
            .FMul, .IMul => try emitBinOp(module, names, inst, "*", w, arena),
            .FDiv, .SDiv, .UDiv => try emitBinOp(module, names, inst, "/", w, arena),
            .FMod => try emitBinOp(module, names, inst, "%", w, arena),
            .UMod, .SRem, .SMod, .FRem => try emitBinOp(module, names, inst, "%", w, arena),
            .ShiftLeftLogical => try emitBinOp(module, names, inst, "<<", w, arena),
            .ShiftRightLogical => try emitBinOp(module, names, inst, ">>", w, arena),
            .FNegate, .SNegate => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try w.print("    var {s}: {s} = -{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .VectorTimesScalar, .MatrixTimesScalar => try emitBinOp(module, names, inst, "*", w, arena),
            .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => {
                // WGSL uses mul() — wait, WGSL doesn't have mul(). Use matrix multiplication operator *
                try emitBinOp(module, names, inst, "*", w, arena);
            },

            // Dot product
            .Dot => try emitCall(module, names, inst, "dot", w, arena),

            // Comparisons
            .FOrdEqual, .IEqual => try emitBinOp(module, names, inst, "==", w, arena),
            .FOrdNotEqual, .INotEqual => try emitBinOp(module, names, inst, "!=", w, arena),
            .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(module, names, inst, "<", w, arena),
            .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(module, names, inst, ">", w, arena),
            .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(module, names, inst, "<=", w, arena),
            .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(module, names, inst, ">=", w, arena),

            // Logical
            .LogicalOr => try emitBinOp(module, names, inst, "or", w, arena),
            .LogicalAnd => try emitBinOp(module, names, inst, "and", w, arena),
            .LogicalNot => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try w.print("    var {s}: {s} = !{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "true" });
            },

            // Select (ternary)
            .Select => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const cond = names.get(inst.words[3]) orelse "c";
                const true_val = names.get(inst.words[4]) orelse "t";
                const false_val = names.get(inst.words[5]) orelse "f";
                try w.print("    var {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
            },

            // Conversions
            .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
            .UConvert, .SConvert, .FConvert, .Bitcast => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const val = names.get(inst.words[3]) orelse "0";
                try w.print("    var {s}: {s} = {s}({s});\n", .{ result_name, rt, rt, val });
            },

            // Texture sampling
            .ImageSampleImplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                // Get texture name directly from combined sampler ID
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try w.print("    var {s}: {s} = textureSample({s}, {s}_sampler, {s});\n", .{ result_name, rt, tex_name, tex_name, coord });
            },

            .ImageSampleExplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const lod = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try w.print("    var {s}: {s} = textureSampleLevel({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, lod });
            },

            .ImageSampleDrefImplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try w.print("    var {s}: {s} = textureSampleCompare({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref });
            },

            .ImageSampleDrefExplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                const lod = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try w.print("    var {s}: {s} = textureSampleCompareLevel({s}, {s}_sampler, {s}, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref, lod });
            },

            .ImageFetch => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const si = names.get(inst.words[3]) orelse "tex";
                const coord = names.get(inst.words[4]) orelse "uv";
                try w.print("    var {s}: {s} = textureLoad({s}, {s});\n", .{ result_name, rt, si, coord });
            },

            // Return
            .Return => {
                // Return is handled by the wrapper code that returns the output var
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
                        const func_name = switch (instruction) {
                            // glslpp's internal GLSL.std.450 opcode numbering (from semantic.zig)
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
                            36 => "modf",
                            37 => "min",
                            40 => "max",
                            43 => "clamp",
                            46 => "mix",
                            48 => "step",
                            49 => "smoothstep",
                            50 => "fma",
                            52 => "frexp",
                            53 => "ldexp",
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
                            // Geometric — glslpp numbering starts at 66
                            66 => "length",
                            67 => "distance",
                            68 => "cross",
                            69 => "normalize",
                            70 => "faceForward",
                            71 => "reflect",
                            72 => "refract",
                            73 => "findILsb",
                            74 => "findSMsb",
                            else => "unknown",
                        };
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
                        try w.print("    var {s}: {s} = {s}({s});\n", .{ result_name, rt, wgsl_name, args.items });
                    }
                }
            },

            // Function call
            .FunctionCall => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const func_id = inst.words[3];
                const func_name = names.get(func_id) orelse "func";
                var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
                defer args.deinit(arena);
                for (inst.words[4..], 0..) |arg_id, ai| {
                    if (ai > 0) try args.appendSlice(arena, ", ");
                    try args.appendSlice(arena, names.get(arg_id) orelse "0");
                }
                if (std.mem.eql(u8, rt, "void")) {
                    try w.print("    {s}({s});\n", .{ func_name, args.items });
                } else {
                    try w.print("    var {s}: {s} = {s}({s});\n", .{ result_name, rt, func_name, args.items });
                }
            },

            // Bitwise
            .BitwiseOr => try emitBinOp(module, names, inst, "|", w, arena),
            .BitwiseXor => try emitBinOp(module, names, inst, "^", w, arena),
            .BitwiseAnd => try emitBinOp(module, names, inst, "&", w, arena),
            .Not => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try w.print("    var {s}: {s} = ~{s};\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .BitReverse => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try w.print("    var {s}: {s} = reverseBits({s});\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },
            .BitCount => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                try w.print("    var {s}: {s} = countOneBits({s});\n", .{ names.get(inst.words[2]) orelse "v", rt, names.get(inst.words[3]) orelse "0" });
            },

            // Derivatives
            .DPdx => try emitCall(module, names, inst, "dpdx", w, arena),
            .DPdy => try emitCall(module, names, inst, "dpdy", w, arena),
            .DPdxCoarse => try emitCall(module, names, inst, "dpdxCoarse", w, arena),
            .DPdyCoarse => try emitCall(module, names, inst, "dpdyCoarse", w, arena),
            .FwidthCoarse => try emitCall(module, names, inst, "fwidthCoarse", w, arena),
            .Fwidth => try emitCall(module, names, inst, "fwidth", w, arena),

            // Return value
            .ReturnValue => {
                const val = names.get(inst.words[1]) orelse "v";
                try w.print("    return {s};\n", .{val});
            },

            // Kill (discard in fragment)
            .Kill => {
                try w.writeAll("    discard;\n");
            },

            // Unreachable
            .Unreachable => {
                try w.writeAll("    unreachable;\n");
            },

            // Undef — zero-initialize
            .Undef => {
                if (inst.words.len > 2) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const rn = names.get(inst.words[2]) orelse "v";
                    try w.print("    var {s}: {s}; // undef\n", .{ rn, rt });
                }
            },

            // Nop
            .Nop => {},

            // All/Any (vector boolean reduction)
            .All => try emitCall(module, names, inst, "all", w, arena),
            .Any => try emitCall(module, names, inst, "any", w, arena),

            // IsInf/IsNan
            .IsInf => try emitCall(module, names, inst, "isinf", w, arena),
            .IsNan => try emitCall(module, names, inst, "isnan", w, arena),

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
                try w.print("    var {s}: {s} = {s};\n", .{ result_name, rt, composite });
                try w.print("    {s}{s} = {s};\n", .{ result_name, access.items, object });
            },

            // VectorExtractDynamic
            .VectorExtractDynamic => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const vector = names.get(inst.words[3]) orelse "vec";
                const index = names.get(inst.words[4]) orelse "i";
                try w.print("    var {s}: {s} = {s}[{s}];\n", .{ result_name, rt, vector, index });
            },

            // Transpose
            .Transpose => try emitCall(module, names, inst, "transpose", w, arena),

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
                try w.print("    var {s}: {s} = textureDimensions({s});\n", .{ result_name, rt, image });
            },

            // ImageQuerySizeLod
            .ImageQuerySizeLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "tex";
                const lod = names.get(inst.words[4]) orelse "0";
                try w.print("    var {s}: {s} = textureDimensions({s}, {s});\n", .{ result_name, rt, image, lod });
            },

            // ImageGather
            .ImageGather => {
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
                try w.print("    var {s}: {s} = textureGather({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, component });
            },

            // ImageRead (storage image load)
            .ImageRead => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const image = names.get(inst.words[3]) orelse "img";
                const coord = names.get(inst.words[4]) orelse "uv";
                try w.print("    var {s}: {s} = textureLoad({s}, {s});\n", .{ result_name, rt, image, coord });
            },

            // ImageWrite (storage image store)
            .ImageWrite => {
                const image = names.get(inst.words[1]) orelse "img";
                const coord = names.get(inst.words[2]) orelse "uv";
                const texel = names.get(inst.words[3]) orelse "color";
                try w.print("    textureStore({s}, {s}, {s});\n", .{ image, coord, texel });
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
                try w.print("    var {s}: {s} = {s};\n", .{ result_name, rt, val });
            },

            // CopyMemory
            .CopyMemory => {
                if (inst.words.len >= 3) {
                    const dst = names.get(inst.words[1]) orelse "dst";
                    const src = names.get(inst.words[2]) orelse "src";
                    try w.print("    {s} = {s};\n", .{ dst, src });
                }
            },

            // ShiftRightArithmetic
            .ShiftRightArithmetic => try emitBinOp(module, names, inst, ">>", w, arena),

            // ControlBarrier / MemoryBarrier
            .ControlBarrier => {
                try w.writeAll("    workgroupBarrier();\n");
            },
            .MemoryBarrier => {
                try w.writeAll("    storageBarrier();\n");
            },

            // Atomic operations
            .AtomicIAdd => try emitAtomicBinOp(module, names, inst, "Add", w, arena),
            .AtomicISub => try emitAtomicBinOp(module, names, inst, "Sub", w, arena),
            .AtomicAnd => try emitAtomicBinOp(module, names, inst, "And", w, arena),
            .AtomicOr => try emitAtomicBinOp(module, names, inst, "Or", w, arena),
            .AtomicXor => try emitAtomicBinOp(module, names, inst, "Xor", w, arena),
            .AtomicUMin, .AtomicSMin => try emitAtomicBinOp(module, names, inst, "Min", w, arena),
            .AtomicUMax, .AtomicSMax => try emitAtomicBinOp(module, names, inst, "Max", w, arena),
            .AtomicExchange => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                const val = names.get(inst.words[4]) orelse "0";
                try w.print("    var {s}: {s} = atomicExchange(&{s}, {s});\n", .{ rn, rt, ptr, val });
            },
            .AtomicCompareExchange => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const rn = names.get(inst.words[2]) orelse "v";
                const ptr = names.get(inst.words[3]) orelse "ptr";
                // words[4] = scope, words[5] = memory semantics
                const cmp = if (inst.words.len > 6) names.get(inst.words[6]) orelse "0" else "0";
                const val = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
                try w.print("    var {s}: {s} = atomicCompareExchangeWeak(&{s}, {s}, {s}).old_value;\n", .{ rn, rt, ptr, cmp, val });
            },

            else => {
                // Try to handle as a simple assignment
                if (inst.words.len > 2) {
                    const rt = try wgslType(module, inst.words[1], names, arena);
                    const rn = names.get(inst.words[2]) orelse "v";
                    try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
                    try w.print("    var {s}: {s};\n", .{ rn, rt });
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Emit helpers
// ---------------------------------------------------------------------------

fn emitBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const lhs = names.get(inst.words[3]) orelse "a";
    const rhs = names.get(inst.words[4]) orelse "b";
    try w.print("    var {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op, rhs });
}

fn emitCall(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, arena: std.mem.Allocator) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    var args = std.ArrayList(u8).initCapacity(arena, 64) catch return;
    defer args.deinit(arena);
    for (inst.words[3..], 0..) |arg_id, ai| {
        if (ai > 0) try args.appendSlice(arena, ", ");
        try args.appendSlice(arena, names.get(arg_id) orelse "0");
    }
    try w.print("    var {s}: {s} = {s}({s});\n", .{ result_name, rt, func, args.items });
}

fn emitAtomicBinOp(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, arena: std.mem.Allocator) !void {
    const rt = try wgslType(module, inst.words[1], names, arena);
    const result_name = names.get(inst.words[2]) orelse "v";
    const ptr = names.get(inst.words[3]) orelse "ptr";
    const val = if (inst.words.len > 4) names.get(inst.words[4]) orelse "0" else "0";
    try w.print("    var {s}: {s} = atomic{s}(&{s}, {s});\n", .{ result_name, rt, op, ptr, val });
}
