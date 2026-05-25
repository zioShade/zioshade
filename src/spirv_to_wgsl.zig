// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → WGSL (WebGPU Shading Language) cross-compiler backend.

const std = @import("std");
const spirv = @import("spirv.zig");
const common = @import("spirv_cross_common.zig");

const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = common.DecorationEntry;

/// Options for SPIR-V → WGSL cross-compilation.
/// Currently empty — reserved for future options.
pub const WgslCompileOptions = struct {
    /// Entry point name to compile (default: "main").
    entry_point_name: []const u8 = "main",
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

fn isWgslKeyword(name: []const u8) bool {
    const reserved = [_][]const u8{ "fn", "let", "var", "const", "if", "else", "for", "while", "loop", "switch", "case", "default", "break", "continue", "return", "struct", "type", "true", "false", "discard", "enable", "override", "private", "storage", "uniform", "workgroup", "function", "array", "atomic", "bool", "f16", "f32", "i32", "u32", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4", "ptr", "vec2", "vec3", "vec4" };
    for (&reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

fn wgslSafeName(name: []const u8, buf: *[64]u8) []const u8 {
    if (!isWgslKeyword(name)) return name;
    const result = std.fmt.bufPrint(buf, "{s}_", .{name}) catch return name;
    return buf[0..result.len];
}

fn getMemberName(module: *const ParsedModule, struct_id: u32, member_idx: u32, buf: *[32]u8) []const u8 {
    const raw = common.commonGetMemberName(module.instructions, struct_id, member_idx, buf, "_");
    if (!isWgslKeyword(raw)) return raw;
    // Keyword conflict: append _ to the existing buffer
    if (raw.len + 1 <= buf.len) {
        buf[raw.len] = '_';
        return buf[0 .. raw.len + 1];
    }
    return raw;
}

fn getArraySuffix(module: *const ParsedModule, ptr_type_id: u32) ![]const u8 {
    return common.commonGetArraySuffix(module.instructions, module.id_defs, ptr_type_id, false);
}

fn emitStructForwardDecls(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), root_type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    const inst = getDef(module, root_type_id) orelse return;
    switch (inst.op) {
        .TypeStruct => {
            try emitOneStructForwardDecl(module, names, root_type_id, w, alloc, emitted, emitted_names);
        },
        .TypePointer => if (inst.words.len > 3) try emitStructForwardDecls(module, names, inst.words[3], w, alloc, emitted, emitted_names),
        .TypeArray => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names),
        .TypeMatrix, .TypeVector => if (inst.words.len > 2) try emitStructForwardDecls(module, names, inst.words[2], w, alloc, emitted, emitted_names),
        else => {},
    }
}

fn emitOneStructForwardDecl(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), type_id: u32, w: anytype, alloc: std.mem.Allocator, emitted: *std.AutoHashMap(u32, void), emitted_names: *std.StringHashMap(void)) !void {
    const inst = getDef(module, type_id) orelse return;
    if (inst.op != .TypeStruct) return;
    if (inst.words.len > 2) {
        for (inst.words[2..]) |mt_id| {
            try emitOneStructForwardDecl(module, names, mt_id, w, alloc, emitted, emitted_names);
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
        if (mti) |mi2| {
            if (mi2.op == .TypeArray and mi2.words.len > 3) {
                const et = try wgslType(module, mi2.words[2], names, alloc);
                const li = getDef(module, mi2.words[3]);
                const lv: u32 = if (li) |l| l.words[3] else 1;
                try w.print("    {s}: array<{s}, {d}>,\n", .{ mname, et, lv });
                continue;
            }
        }
        const mt = try wgslType(module, mt_id, names, alloc);
        try w.print("    {s}: {s},\n", .{ mname, mt });
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
            // Check if multisampled (words[6]) or storage (words[7] == 2)
            const is_ms = if (inst.words.len > 6) inst.words[6] == 1 else false;
            const is_storage = if (inst.words.len > 7) inst.words[7] == 2 else false;
            if (is_storage) {
                // Storage image: texture_storage_2d<rgba8unorm, write>
                const format: []const u8 = switch (dim) {
                    1 => "texture_storage_2d<rgba8unorm, write>",
                    2 => "texture_storage_3d<rgba8unorm, write>",
                    else => "texture_storage_2d<rgba8unorm, write>",
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
        .FunctionCall, .Phi, .Select, .CopyLogical, .FunctionParameter,
        .ConvertFToS, .ConvertSToF, .ConvertUToF, .ConvertFToU,
        .UConvert, .SConvert, .FConvert, .Bitcast,
        .VectorShuffle, .CompositeExtract, .VectorTimesScalar,
        .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector,
        .MatrixTimesMatrix, .OuterProduct, .ImageSampleImplicitLod,
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

    // Emit uniform buffers
    for (cbuffers.items) |cb| {
        const group = @divFloor(cb.binding, 2);
        const binding = cb.binding;
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
        if (cb.is_ssbo) {
            try w.print("@group({d}) @binding({d})\nvar<storage, read_write> {s}: ", .{ group, binding, var_name });
        } else {
            try w.print("@group({d}) @binding({d})\nvar<uniform> {s}: ", .{ group, binding, var_name });
        }
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
        try emitBody(&module, &names, &decorations, fidx, w, alloc, arena, inout_ret_name, null);

        try w.writeAll("}\n\n");
    }

    // Emit VertexOutput struct if vertex shader has multiple outputs
    var vertex_output_fields = std.ArrayList(struct { name: []const u8, type_name: []const u8, builtin: ?[]const u8, location: ?u32 }).initCapacity(arena, 4) catch return error.OutOfMemory;
    // Detect depth output for fragment shaders
    var use_frag_depth_struct = false;
    if (is_fragment and depth_output_var_id != null) {
        try w.writeAll("struct FragmentOutput {\n");
        try w.writeAll("    @location(0) color: vec4f,\n");
        try w.writeAll("    @builtin(frag_depth) depth: f32,\n");
        try w.writeAll("}\n\n");
        use_frag_depth_struct = true;
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
        for (vertex_output_fields.items) |field| {
            if (field.builtin) |bi| {
                try w.print("    @builtin({s}) {s}: {s},\n", .{ bi, field.name, field.type_name });
            } else if (field.location) |loc| {
                try w.print("    @location({d}) {s}: {s},\n", .{ loc, field.name, field.type_name });
            } else {
                try w.print("    {s}: {s},\n", .{ field.name, field.type_name });
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
        if (use_frag_depth_struct) {
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
        }
        if (store_count == 1 and last_stored_value != null) {
            direct_return_value = last_stored_value.?;
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

    // Emit function body
    try emitBody(&module, &names, &decorations, entry_func_idx.?, w, alloc, arena, null, if (skip_output_var_decl) output_var_id else null);

    // Return output var
    if (use_frag_depth_struct) {
        const color_val = direct_return_value orelse (if (output_var_id != null) names.get(output_var_id.?) orelse "vec4f()" else "vec4f()");
        const depth_val = depth_return_value orelse "0.0";
        try w.print("    return FragmentOutput({s}, {s});\n", .{ color_val, depth_val });
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

        // Look for reassignment pattern: '<name> = ...' (not '==')
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len > 0) {
            if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
                const potential_name = trimmed[0..space_idx];
                if (space_idx + 2 < trimmed.len and trimmed[space_idx + 1] == '=' and trimmed[space_idx + 2] != '=') {
                    const name_copy = try arena.dupe(u8, potential_name);
                    try mutable_names.put(name_copy, {});
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

fn emitBody(module: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decorations: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), func_idx: usize, w: anytype, alloc: std.mem.Allocator, arena: std.mem.Allocator, inout_return: ?[]const u8, skip_store_target: ?u32) !void {
    _ = decorations;
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
                }
            }
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
                                    if (cinst.op == .LoopMerge or cinst.op == .FunctionEnd) break;
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
                                    if (cinst.op == .LoopMerge or cinst.op == .FunctionEnd) break;
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
                    try writeInd(w, indent); try w.print("let {s}: {s} = {s};\n", .{ result_name, rt, expr });
                    if (expr_allocated) alloc.free(expr);
                }
            },

            // Store
            .Store => {
                // Skip store to output variable when doing direct return
                if (skip_store_target != null and inst.words[1] == skip_store_target.?) continue;
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
                    if (lead_count >= 2 and lead_source != null) {
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
                // Check if all components come from the same source vector (single-source swizzle)
                var single_source = true;
                for (inst.words[5..]) |idx| {
                    if (idx >= 4) { single_source = false; break; }
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
                        const src = if (idx < 4) v1 else v2;
                        const comp = idx % 4;
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
            .ShiftLeftLogical => try emitBinOp(module, names, &inline_exprs, inst, "<<", w, arena, indent),
            .ShiftRightLogical => try emitBinOp(module, names, &inline_exprs, inst, ">>", w, arena, indent),
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
                try writeInd(w, indent); try w.print("let {s}: {s} = select({s}, {s}, {s});\n", .{ result_name, rt, false_val, true_val, cond });
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
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureSampleCompare({s}, {s}_sampler, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref });
            },

            .ImageSampleDrefExplicitLod => {
                const rt = try wgslType(module, inst.words[1], names, arena);
                const result_name = names.get(inst.words[2]) orelse "v";
                const coord = names.get(inst.words[4]) orelse "uv";
                const dref = if (inst.words.len > 5) names.get(inst.words[5]) orelse "0" else "0";
                const lod = if (inst.words.len > 7) names.get(inst.words[7]) orelse "0" else "0";
                const tex_name = names.get(inst.words[3]) orelse "tex";
                try writeInd(w, indent); try w.print("let {s}: {s} = textureSampleCompareLevel({s}, {s}_sampler, {s}, {s}, {s});\n", .{ result_name, rt, tex_name, tex_name, coord, dref, lod });
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
                            35 => "modf", // ModfStruct
                            36 => "modf",
                            37 => "min",
                            38 => "min", // SMin
                            39 => "min", // UMin
                            40 => "max",
                            41 => "max", // UMax
                            42 => "max", // SMax
                            43 => "clamp",
                            44 => "clamp", // UClamp
                            45 => "clamp", // SClamp
                            46 => "mix",
                            48 => "step",
                            49 => "smoothstep",
                            50 => "fma",
                            51 => "frexp", // FrexpStruct
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

            // ShiftRightArithmetic
            .ShiftRightArithmetic => try emitBinOp(module, names, &inline_exprs, inst, ">>", w, arena, indent),

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
    try writeIndentStatic(w, indent); try w.print("let {s}: {s} = {s} {s} {s};\n", .{ result_name, rt, lhs, op, rhs });
}

// Check if a string is a compound expression (contains operators at depth 0)
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
                const func_name = switch (instruction) {
                    1 => "round", 2 => "round", 3 => "trunc", 4 => "abs", 5 => "abs",
                    6 => "sign", 7 => "sign", 8 => "floor", 9 => "ceil", 10 => "fract",
                    11 => "radians", 12 => "degrees", 13 => "sin", 14 => "cos", 15 => "tan",
                    16 => "asin", 17 => "acos", 18 => "atan", 19 => "sinh", 20 => "cosh",
                    21 => "tanh", 22 => "asinh", 23 => "acosh", 24 => "atanh",
                    25 => "atan2", 26 => "pow", 27 => "exp", 28 => "log", 29 => "exp2",
                    30 => "log2", 31 => "sqrt", 32 => "inverseSqrt", 33 => "determinant",
                    34 => "matrixInverse", 35 => "modf", 37 => "min", 38 => "min", 39 => "min", 40 => "max", 41 => "max", 42 => "max", 43 => "clamp", 44 => "clamp", 45 => "clamp",
                    46 => "mix", 48 => "step", 49 => "smoothstep", 50 => "fma", 51 => "frexp",
                    66 => "length", 67 => "distance", 68 => "cross", 69 => "normalize",
                    70 => "faceForward", 71 => "reflect", 72 => "refract",
                    else => "unknown",
                };
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

// Get the WGSL function name for a GLSL.std.450 instruction opcode
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

