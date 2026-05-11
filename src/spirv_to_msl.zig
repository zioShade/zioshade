// SPDX-License-Identifier: MIT OR Apache-2.0
//! SPIR-V binary → MSL (Metal Shading Language) cross-compiler backend.
//! Self-contained: includes its own parser, name resolver, and MSL emitter.

const compat = @import("compat.zig");
const std = @import("std");
const spirv = @import("spirv.zig");

const common = @import("spirv_cross_common.zig");
const Instruction = common.Instruction;
const ParsedModule = common.ParsedModule;
const DecorationEntry = struct { decoration: spirv.Decoration, extra: []const u32 };
const CbufferDecl = struct { name: []const u8, type_id: u32, binding: u32 };
const TextureDecl = struct { name: []const u8, binding: u32 };

// ---- Helpers ----
fn getDef(m: *const ParsedModule, id: u32) ?Instruction { if (id >= m.id_defs.len) return null; const i = m.id_defs[id] orelse return null; if (i >= m.instructions.len) return null; return m.instructions[i]; }
fn swizzleChar(i: u32) []const u8 { return switch(i){ 0=>".x",1=>".y",2=>".z",3=>".w",else=>".x"}; }
fn parseLitStr(alloc: std.mem.Allocator, words: []const u32) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, words.len*4); for(words)|word|{const bytes:[4]u8=@bitCast(word);for(bytes)|c|{if(c==0)break;buf.appendAssumeCapacity(c);}} return buf.toOwnedSlice(alloc); }
fn sanitizeName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 { var buf = try std.ArrayList(u8).initCapacity(alloc, name.len); for(name)|c|{switch(c){'a'...'z','A'...'Z','0'...'9','_'=>buf.appendAssumeCapacity(c),else=>buf.appendAssumeCapacity('_'),}} return buf.toOwnedSlice(alloc); }
fn isUniformVar(m: *const ParsedModule, id: u32) bool { const inst = getDef(m, id) orelse return false; if (inst.op == .Variable and inst.words.len >= 4) { const sc: spirv.StorageClass = @enumFromInt(inst.words[3]); return sc == .Uniform; } return false; }

fn resolvePointee(m: *const ParsedModule, id: u32) ?u32 {
    const inst = getDef(m, id) orelse return null;
    switch(inst.op) {
        .Variable => { const pt = getDef(m, inst.words[1]) orelse return null; if (pt.op == .TypePointer and pt.words.len > 3) return pt.words[3]; return null; },
        .AccessChain => {
            var cur = resolvePointee(m, inst.words[3]);
            for (inst.words[4..]) |idx_id| {
                const idx_def = getDef(m, idx_id);
                if (cur) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) {
                            cur = tinst.words[2];
                        } else if (tinst.op == .TypeStruct) {
                            if (idx_def) |d| {
                                if (d.op == .Constant and d.words.len > 3) {
                                    const v = d.words[3];
                                    if (v + 2 < tinst.words.len) { cur = tinst.words[v + 2]; } else cur = null;
                                }
                            }
                        } else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) {
                            cur = tinst.words[2];
                        } else {
                            cur = null;
                        }
                    } else {
                        cur = null;
                    }
                } else {
                    cur = null;
                }
            }
            return cur;
        },
        else => return null,
    }
}

fn buildAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, alloc: std.mem.Allocator) ![]const u8 {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) return try alloc.dupe(u8, base_name);
    // Use a stack buffer to avoid heap allocation for typical access chains
    var writer = compat.StackBufWriter(512).init();
    writer.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    writer.writeAll(swizzleChar(val));
                } else {
                    writer.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                        else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            } else { writer.print("[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { writer.print("[{s}]", .{names.get(index_id) orelse "i"}); }
    }
    if (!writer.overflowed()) {
            return try alloc.dupe(u8, writer.written());
    }
    // Fallback to heap for long chains
    var buf = std.ArrayList(u8).initCapacity(alloc, 256) catch return error.OutOfMemory;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, base_name);
    cur_type = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) { try buf.appendSlice(alloc, swizzleChar(val)); }
                else { try buf.print(alloc, "[{d}]", .{val}); }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
                    if (ti) |tinst| {
                        if (tinst.op == .TypeVector) { cur_type = tinst.words[2]; }
                        else if (tinst.op == .TypeStruct and val + 2 < tinst.words.len) { cur_type = tinst.words[val + 2]; }
                        else if (tinst.op == .TypeArray or tinst.op == .TypeMatrix) { cur_type = tinst.words[2]; }
                        else { cur_type = null; }
                    }
                }
            } else { try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"}); }
        } else { try buf.print(alloc, "[{s}]", .{names.get(index_id) orelse "i"}); }
    }
    return buf.toOwnedSlice(alloc);
}

fn writeResolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, w: anytype) !void {
    const inst = getDef(m, ptr_id) orelse { try w.writeAll(names.get(ptr_id) orelse "var"); return; };
    if (inst.op == .AccessChain) {
        try writeAccessExpr(m, names, inst.words[3], inst.words[4..], w);
        return;
    }
    try w.writeAll(names.get(ptr_id) orelse "var");
}

fn writeAccessExpr(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), base_id: u32, indices: []const u32, w: anytype) !void {
    const base_name = names.get(base_id) orelse "base";
    if (indices.len == 0) { try w.writeAll(base_name); return; }
    try w.writeAll(base_name);
    var cur_type: ?u32 = resolvePointee(m, base_id);
    for (indices) |index_id| {
        const idx_inst = getDef(m, index_id);
        if (idx_inst) |def| {
            if (def.op == .Constant and def.words.len > 3) {
                const val = def.words[3];
                const is_vector = if (cur_type) |tid| blk: { const ti = getDef(m, tid); break :blk ti != null and ti.?.op == .TypeVector; } else false;
                if (is_vector) {
                    try w.writeAll(swizzleChar(val));
                } else {
                    try w.print("[{d}]", .{val});
                }
                if (cur_type) |tid| {
                    const ti = getDef(m, tid);
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

fn resolvePointer(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), ptr_id: u32, alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, ptr_id) orelse { const n = names.get(ptr_id) orelse "var"; return try alloc.dupe(u8, n); };
    if (inst.op == .AccessChain) return try buildAccessExpr(m, names, inst.words[3], inst.words[4..], alloc);
    const n = names.get(ptr_id) orelse "var";
    return try alloc.dupe(u8, n);
}

// ---- MSL type resolution ----
fn mslType(m: *const ParsedModule, type_id: u32, names: *std.AutoHashMap(u32, []const u8), alloc: std.mem.Allocator) ![]const u8 {
    const inst = getDef(m, type_id) orelse return "float4";
    return switch (inst.op) {
        .TypeVoid => "void",
        .TypeBool => "bool",
        .TypeInt => if (inst.words.len > 3 and inst.words[3] != 0) "int" else "uint",
        .TypeFloat => if (inst.words.len > 2 and inst.words[2] == 16) "half" else "float",
        .TypeVector => {
            const scalar = mslType(m, inst.words[2], names, alloc) catch "float";
            const count = inst.words[3];
            if (std.mem.eql(u8, scalar, "float")) { if(count>=1 and count<=4) return ([_][]const u8{"","float","float2","float3","float4"})[count]; }
            else if (std.mem.eql(u8, scalar, "half")) { if(count>=1 and count<=4) return ([_][]const u8{"","half","half2","half3","half4"})[count]; }
            else if (std.mem.eql(u8, scalar, "int")) { if(count>=1 and count<=4) return ([_][]const u8{"","int","int2","int3","int4"})[count]; }
            else if (std.mem.eql(u8, scalar, "uint")) { if(count>=1 and count<=4) return ([_][]const u8{"","uint","uint2","uint3","uint4"})[count]; }
            else if (std.mem.eql(u8, scalar, "bool")) { if(count>=1 and count<=4) return ([_][]const u8{"","bool","bool2","bool3","bool4"})[count]; }
            return std.fmt.allocPrint(alloc, "{s}{d}", .{scalar, count});
        },
        .TypeMatrix => {
            const cols = inst.words[3];
            const ct = getDef(m, inst.words[2]);
            const rows: u32 = if (ct) |c| c.words[3] else cols;
            if (cols == rows) {
                if (cols == 2) return "float2x2";
                if (cols == 3) return "float3x3";
                if (cols == 4) return "float4x4";
            }
            if (cols == 2 and rows == 3) return "float2x3";
            if (cols == 2 and rows == 4) return "float2x4";
            if (cols == 3 and rows == 2) return "float3x2";
            if (cols == 3 and rows == 4) return "float3x4";
            if (cols == 4 and rows == 2) return "float4x2";
            if (cols == 4 and rows == 3) return "float4x3";
            return std.fmt.allocPrint(alloc, "float{d}x{d}", .{cols, rows});
        },
        .TypeArray, .TypeRuntimeArray => mslType(m, inst.words[2], names, alloc),
        .TypePointer => if (inst.words.len > 3) mslType(m, inst.words[3], names, alloc) else "float4",
        .TypeStruct => names.get(type_id) orelse "Struct",
        else => "float4",
    };
}

fn constantLiteral(alloc: std.mem.Allocator, type_inst: Instruction, literal_words: []const u32) ![]const u8 {
    if (type_inst.op == .TypeFloat and literal_words.len > 0) {
        const val: f32 = @bitCast(literal_words[0]);
        if (val == @floor(val) and @abs(val) < 1e6) { const ival: i32 = @intFromFloat(val); return std.fmt.allocPrint(alloc, "{d}.0", .{ival}); }
        return std.fmt.allocPrint(alloc, "{d}", .{val});
    }
    if (type_inst.op == .TypeInt and literal_words.len > 0) {
        const signed = type_inst.words.len > 3 and type_inst.words[3] != 0;
        if (signed) { const val: i32 = @bitCast(literal_words[0]); return std.fmt.allocPrint(alloc, "{d}", .{val}); }
        else return std.fmt.allocPrint(alloc, "{d}u", .{literal_words[0]});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{literal_words[0]});
}

fn getDecVal(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) ?u32 {
    const list = decs.get(id) orelse return null;
    for (list.items) |e| { if (e.decoration == dec and e.extra.len > 0) return e.extra[0]; }
    return null;
}

fn hasDec(decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), id: u32, dec: spirv.Decoration) bool {
    const list = decs.get(id) orelse return false;
    for (list.items) |e| { if (e.decoration == dec) return true; }
    return false;
}

// ---- Public API ----
pub const MslCompileOptions = struct { metal_version: u32 = 21 };

pub fn spirvToMSL(alloc: std.mem.Allocator, spirv_words: []const u32, options: MslCompileOptions) ![]const u8 {
    _ = options;
    var module = try parseModule(alloc, spirv_words);
    defer module.deinit(alloc);
    const entry_id = module.entry_point_id orelse return error.NoEntryPoint;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var names = std.AutoHashMap(u32, []const u8).init(aa);
    defer names.deinit();
    var decs = std.AutoHashMap(u32, std.ArrayList(DecorationEntry)).init(aa);
    defer decs.deinit();

    collectNames(aa, &module, &names);
    try collectDecorations(aa, &module, &decs);

    var cbuffers = std.ArrayList(CbufferDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer cbuffers.deinit(aa);
    var textures = std.ArrayList(TextureDecl).initCapacity(aa, 0) catch return error.OutOfMemory;
    defer textures.deinit(aa);
    collectResources(&module, &names, &decs, &cbuffers, &textures, aa);

    var output = std.ArrayList(u8).initCapacity(alloc, 4096) catch return error.OutOfMemory;
    var output_owned = true;
    defer if (output_owned) output.deinit(alloc);
    const w = compat.listWriter(&output, alloc);

    const is_compute = module.execution_model == .GLCompute;
    const is_frag = module.execution_model == .Fragment;

    // MSL header
    try w.writeAll("#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n");

    // Emit uniform blocks as structs
    for (cbuffers.items) |cb| {
        try w.print("struct {s}\n{{\n", .{cb.name});
        try emitStructMembers(&module, &names, cb.type_id, cb.name, w, aa);
        try w.writeAll("};\n\n");
    }

    // Collect SSBO-style storage buffers (StorageBuffer storage class or Uniform + BufferBlock decoration)
    var storage_buffers = std.ArrayList(CbufferDecl).initCapacity(aa, 8) catch return error.OutOfMemory;
    for (module.instructions) |inst| {
        if (inst.op == .Variable and inst.words.len >= 4) {
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            const rid = inst.words[2];
            // SSBOs use StorageBuffer storage class (SPIR-V 1.3+) or Uniform + BufferBlock decoration
            const is_ssbo = sc == .StorageBuffer or (sc == .Uniform and hasDec(&decs, rid, .buffer_block));
            if (!is_ssbo) continue;
            const binding = getDecVal(&decs, rid, .binding) orelse continue;
            const name = names.get(rid) orelse continue;
            const ptr_inst = getDef(&module, inst.words[1]) orelse continue;
            if (ptr_inst.op == .TypePointer and ptr_inst.words.len >= 4) {
                const ptid = ptr_inst.words[3];
                storage_buffers.append(aa, .{ .name = name, .type_id = ptid, .binding = binding }) catch {};
            }
        }
    }

    // Emit storage buffer structs for compute
    if (storage_buffers.items.len > 0) {
        for (storage_buffers.items) |sb| {
            try w.print("struct {s}\n{{\n", .{sb.name});
            try emitStructMembers(&module, &names, sb.type_id, sb.name, w, aa);
            try w.writeAll("};\n\n");
        }
    }

    // Output struct for fragment
    if (is_frag) {
        try w.writeAll("struct main0_out\n{\n    float4 _fragColor [[color(0)]];\n};\n\n");
    }

    var func_ids = std.ArrayList(u32).initCapacity(aa, 8) catch return error.OutOfMemory;
    defer func_ids.deinit(aa);
    for (module.instructions) |inst| { if (inst.op == .Function and inst.words.len > 2) try func_ids.append(aa, inst.words[2]); }

    var out_param_info = std.AutoHashMap(u32, std.ArrayList(usize)).init(aa);
    defer { var it = out_param_info.iterator(); while(it.next())|e| e.value_ptr.deinit(aa); out_param_info.deinit(); }
    detectOutParams(&module, entry_id, &out_param_info, aa);

    // Emit non-entry functions first
    for (func_ids.items) |fid| { if (fid == entry_id) continue; try emitFunction(&module, &names, &decs, fid, w, aa, false, &out_param_info, &cbuffers, &textures, &storage_buffers, is_compute); }
    // Emit entry function last
    try emitFunction(&module, &names, &decs, entry_id, w, aa, true, &out_param_info, &cbuffers, &textures, &storage_buffers, is_compute);
    output_owned = false;
    return output.toOwnedSlice(alloc);
}

// ---- Parser ----
fn parseModule(alloc: std.mem.Allocator, words: []const u32) !ParsedModule {
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] != spirv.MAGIC) return error.InvalidSpirvMagic;
    var instructions = std.ArrayList(Instruction).initCapacity(alloc, words.len / 4) catch return error.OutOfMemory;
    errdefer instructions.deinit(alloc);
    const bound = if (words.len > 3) words[3] else 0;
    const id_defs = try alloc.alloc(?usize, bound);
    @memset(id_defs, null);
    var i: usize = 5;
    while (i < words.len) {
        const hw = words[i]; const wc: u16 = @intCast(hw >> 16); const oc: u16 = @truncate(hw & 0xFFFF);
        if (wc == 0) return error.InvalidSpirv;
        if (i + wc > words.len) return error.InvalidSpirvTruncated;
        const op: spirv.Op = @enumFromInt(oc); const iw = words[i..i+wc];
        if (resultIdFromOp(op, iw)) |id| { if (id < bound) id_defs[id] = instructions.items.len; }
        instructions.append(alloc, .{.op=op,.words=iw}) catch return error.OutOfMemory;
        i += wc;
    }
    const owned = instructions.toOwnedSlice(alloc) catch instructions.items;
    var module = ParsedModule{.instructions=owned,.id_defs=id_defs};
    for (module.instructions) |inst| {
        if (inst.op == .EntryPoint and inst.words.len > 2) { if (module.entry_point_id == null) { module.execution_model = @enumFromInt(inst.words[1]); module.entry_point_id = inst.words[2]; } }
        if (inst.op == .ExecutionMode and inst.words.len >= 3) { const mode: spirv.ExecutionMode = @enumFromInt(inst.words[2]); if (mode == .LocalSize and inst.words.len >= 6) module.local_size = .{inst.words[3],inst.words[4],inst.words[5]}; }
    }
    return module;
}
fn resultIdFromOp(op: spirv.Op, words: []const u32) ?u32 {
    return switch(op) {
        .TypeVoid,.TypeBool,.TypeInt,.TypeFloat,.TypeVector,.TypeMatrix,.TypeImage,.TypeSampler,.TypeSampledImage,.TypeArray,.TypeRuntimeArray,.TypeStruct,.TypePointer,.TypeFunction,.TypeForwardPointer => if(words.len>1) words[1] else null,
        .ConstantTrue,.ConstantFalse,.Constant,.ConstantComposite,.SpecConstant,.Undef => if(words.len>2) words[2] else null,
        .Variable,.Function,.FunctionParameter => if(words.len>2) words[2] else null,
        .Load,.AccessChain,.CompositeConstruct,.CompositeExtract,.VectorShuffle,.SampledImage,.ImageSampleImplicitLod,.ImageSampleExplicitLod,.ImageFetch,.ImageGather,.ImageQuerySizeLod,.ImageQuerySize,.ImageTexelPointer,.FunctionCall,.CopyObject,.Phi,.ConvertFToS,.ConvertSToF,.ConvertUToF,.ConvertFToU,.UConvert,.SConvert,.FConvert,.Bitcast,.SNegate,.FNegate,.IAdd,.FAdd,.ISub,.FSub,.IMul,.FMul,.UDiv,.SDiv,.FDiv,.UMod,.SRem,.FRem,.FMod,.VectorTimesScalar,.MatrixTimesScalar,.VectorTimesMatrix,.MatrixTimesVector,.MatrixTimesMatrix,.Dot,.Transpose,.OuterProduct,.Select,.LogicalOr,.LogicalAnd,.LogicalNot,.IEqual,.INotEqual,.UGreaterThan,.SGreaterThan,.UGreaterThanEqual,.SGreaterThanEqual,.ULessThan,.SLessThan,.ULessThanEqual,.SLessThanEqual,.FOrdEqual,.FOrdNotEqual,.FOrdLessThan,.FOrdGreaterThan,.FOrdLessThanEqual,.FOrdGreaterThanEqual,.ShiftRightLogical,.ShiftRightArithmetic,.ShiftLeftLogical,.BitwiseOr,.BitwiseXor,.BitwiseAnd,.Not,.IsNan,.IsInf,.All,.Any,.DPdx,.DPdy,.Fwidth,.DPdxFine,.DPdyFine,.FwidthFine,.DPdxCoarse,.DPdyCoarse,.FwidthCoarse,.VectorExtractDynamic,.ExtInst,.OpImage,.AtomicIAdd,.AtomicISub,.AtomicExchange,.AtomicSMin,.AtomicUMin,.AtomicSMax,.AtomicUMax,.AtomicAnd,.AtomicOr,.AtomicXor => if(words.len>2) words[2] else null,
        else => null,
    };
}

// ---- Collection passes ----
fn collectNames(alloc: std.mem.Allocator, m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8)) void {
    var counter: u32 = 0;
    for (m.instructions) |inst| {
        if (inst.op == .Name and inst.words.len >= 3) { const id = inst.words[1]; const ns = parseLitStr(alloc, inst.words[2..]) catch continue; const san = sanitizeName(alloc, ns) catch { names.put(id, ns) catch {}; continue; }; alloc.free(ns); names.put(id, san) catch {}; }
        if (inst.op == .Constant and inst.words.len > 3) { const rid = inst.words[2]; const ti = getDef(m, inst.words[1]); if (ti) |t| { const lit = constantLiteral(alloc, t, inst.words[3..]) catch continue; if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value); continue; } }
        if (inst.op == .ConstantTrue and inst.words.len > 2) { const l = alloc.dupe(u8, "true") catch continue; if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value); continue; }
        if (inst.op == .ConstantFalse and inst.words.len > 2) { const l = alloc.dupe(u8, "false") catch continue; if (names.fetchPut(inst.words[2], l) catch null) |old| alloc.free(old.value); continue; }
        if (inst.op == .ConstantComposite and inst.words.len > 3) {
            const rid = inst.words[2];
            const ti = getDef(m, inst.words[1]);
            if (ti) |t| {
                if (t.op == .TypeVector) {
                    const constituents = inst.words[3..];
                    var all_same = true;
                    if (constituents.len > 1) { const first = constituents[0]; for (constituents[1..]) |c| { if (c != first) { all_same = false; break; } } }
                    const vt = mslType(m, inst.words[1], names, alloc) catch "float4";
                    if (all_same and constituents.len > 0) {
                        const val = names.get(constituents[0]) orelse "0.0";
                        const lit = std.fmt.allocPrint(alloc, "{s}({s})", .{vt, val}) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    } else {
                        var buf = std.ArrayList(u8).initCapacity(alloc, 64) catch continue;
                        defer buf.deinit(alloc);
                        buf.print(alloc, "{s}(", .{vt}) catch continue;
                        for (constituents, 0..) |cid, i| { if (i > 0) buf.appendSlice(alloc, ", ") catch continue; buf.appendSlice(alloc, names.get(cid) orelse "0.0") catch continue; }
                        buf.appendSlice(alloc, ")") catch continue;
                        const lit = buf.toOwnedSlice(alloc) catch continue;
                        if (names.fetchPut(rid, lit) catch null) |old| alloc.free(old.value);
                    }
                    continue;
                }
            }
        }
        if (resultIdFromOp(inst.op, inst.words)) |rid| { if (!names.contains(rid)) { const name = std.fmt.allocPrint(alloc, "v{}", .{counter}) catch continue; counter += 1; names.put(rid, name) catch {}; } }
    }
}

fn collectDecorations(alloc: std.mem.Allocator, m: *const ParsedModule, decs: *std.AutoHashMap(u32, std.ArrayList(DecorationEntry))) !void {
    for (m.instructions) |inst| { if (inst.op == .Decorate and inst.words.len >= 3) { const id = inst.words[1]; const dec: spirv.Decoration = @enumFromInt(inst.words[2]); const extra = if(inst.words.len>3) inst.words[3..] else &[_]u32{}; const gop = try decs.getOrPut(id); if(!gop.found_existing) gop.value_ptr.* = std.ArrayList(DecorationEntry).empty; try gop.value_ptr.append(alloc, .{.decoration=dec,.extra=extra}); } }
}

fn collectResources(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)), cb: *std.ArrayList(CbufferDecl), tex: *std.ArrayList(TextureDecl), alloc: std.mem.Allocator) void {
    for (m.instructions) |inst| {
        if (inst.op != .Variable or inst.words.len < 4) continue;
        const rt = inst.words[1]; const rid = inst.words[2]; const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
        const pi = getDef(m, rt) orelse continue; if (pi.op != .TypePointer or pi.words.len < 4) continue;
        const pt = pi.words[3];
        switch (sc) {
            .Uniform => { if (hasDec(decs, rid, .buffer_block)) continue; const binding = getDecVal(decs, rid, .binding) orelse 0; cb.append(alloc, .{.name=names.get(rid) orelse "Globals", .type_id=pt, .binding=binding}) catch {}; },
            .UniformConstant => { const pei = getDef(m, pt) orelse continue; const binding = getDecVal(decs, rid, .binding) orelse 0; const name = names.get(rid) orelse "tex"; switch(pei.op){ .TypeSampledImage=>{tex.append(alloc,.{.name=name,.binding=binding}) catch {};}, .TypeImage=>{tex.append(alloc,.{.name=name,.binding=binding}) catch {};}, else=>{}} },
            else => {},
        }
    }
}

fn emitStructMembers(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), struct_id: u32, cb_name: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    _ = cb_name;
    const inst = getDef(m, struct_id) orelse return; if (inst.op != .TypeStruct) return;
    for (inst.words[2..], 0..) |mt_id, mi| {
        const mti = getDef(m, mt_id); if (mti) |mi2| { if (mi2.op == .TypeArray and mi2.words.len > 3) { const et = try mslType(m, mi2.words[2], names, alloc); const li = getDef(m, mi2.words[3]); const lv: u32 = if(li)|l| l.words[3] else 1; try w.print("    {s} _m{d}[{d}];\n", .{et, mi, lv}); continue; } }
        const mt = try mslType(m, mt_id, names, alloc); try w.print("    {s} _m{d};\n", .{mt, mi});
    }
}

fn detectOutParams(m: *const ParsedModule, entry_id: u32, opi: *std.AutoHashMap(u32, std.ArrayList(usize)), alloc: std.mem.Allocator) void {
    const fi = if (entry_id < m.id_defs.len) m.id_defs[entry_id] orelse return else return;
    var ov = std.AutoHashMap(u32, void).init(alloc); defer ov.deinit();
    for (m.instructions) |inst| { if (inst.op == .Variable and inst.words.len >= 4) { const sc: spirv.StorageClass = @enumFromInt(inst.words[3]); if (sc == .Output) ov.put(inst.words[2], {}) catch {}; } }
    var lfo = std.AutoHashMap(u32, void).init(alloc); defer lfo.deinit();
    for (m.instructions) |inst| { if (inst.op == .Load and inst.words.len >= 4) { if (ov.contains(inst.words[3])) lfo.put(inst.words[2], {}) catch {}; } }
    var idx = fi + 1;
    while (idx < m.instructions.len) : (idx += 1) { const inst = m.instructions[idx]; if (inst.op == .FunctionEnd) break; if (inst.op != .FunctionCall or inst.words.len < 4) continue; const cfid = inst.words[3]; for (inst.words[4..], 0..) |aid, pidx| { if (ov.contains(aid) or lfo.contains(aid)) { const gop = opi.getOrPut(cfid) catch continue; if(!gop.found_existing) gop.value_ptr.* = std.ArrayList(usize).initCapacity(alloc, 4) catch continue; gop.value_ptr.append(alloc, pidx) catch {}; } } }
}

// ---- Std450 → MSL function name mapping ----
fn std450ToMsl(val: u32) ?[]const u8 {
    return switch (val) {
        1 => "round", 3 => "trunc", 4, 5 => "abs", 6 => "sign", 8 => "floor", 9 => "ceil",
        10 => "fract",
        11 => "radians", 12 => "degrees", 13 => "sin", 14 => "cos", 15 => "tan",
        16 => "asin", 17 => "acos", 18 => "atan", 25 => "atan2",
        19 => "sinh", 20 => "cosh", 21 => "tanh",
        26 => "powr", 27 => "exp", 28 => "log", 29 => "exp2", 30 => "log2",
        31 => "sqrt", 32 => "rsqrt", 33 => "determinant",
        37 => "min", 38 => "max", 39 => "min",
        40 => "max", 41 => "min", 42 => "max", 43 => "clamp", 44 => "clamp",
        45 => "fast::clamp", 46 => "mix", 48 => "step", 49 => "smoothstep",
        66 => "length", 67 => "distance", 68 => "cross", 69 => "normalize",
        70 => "faceforward", 71 => "reflect", 72 => "refract",
        else => null,
    };
}

// ---- Function emission (MSL dialect) ----

fn emitFunction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_id: u32,
    w: anytype,
    alloc: std.mem.Allocator,
    is_entry: bool,
    opi: *const std.AutoHashMap(u32, std.ArrayList(usize)),
    cbuffers: *const std.ArrayList(CbufferDecl),
    textures: *const std.ArrayList(TextureDecl),
    storage_buffers: *const std.ArrayList(CbufferDecl),
    is_compute: bool,
) !void {
    const fi = getDef(m, func_id) orelse return;
    if (fi.op != .Function or fi.words.len < 5) return;
    const fti = getDef(m, fi.words[4]) orelse return;
    const rtid = fti.words[2];
    const rt = try mslType(m, rtid, names, alloc);
    const is_frag = is_entry and m.execution_model == .Fragment;

    const func_idx = if (func_id < m.id_defs.len) m.id_defs[func_id] orelse return else return;
    const func_name = if (is_entry) "main0" else (names.get(func_id) orelse "func");

    var param_ids = std.ArrayList(u32).initCapacity(alloc, 4) catch return error.OutOfMemory;
    defer param_ids.deinit(alloc);
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionParameter) {
                try param_ids.append(alloc, inst.words[2]);
            } else if (inst.op != .Label) {
                break;
            }
        }
    }

    // Out-param detection
    var out_param_var_ids = std.AutoHashMap(u32, u32).init(alloc);
    defer out_param_var_ids.deinit();
    {
        var si = func_idx + 1;
        while (si < m.instructions.len) : (si += 1) {
            const scan = m.instructions[si];
            if (scan.op == .FunctionEnd) break;
            if (scan.op == .Label or scan.op == .FunctionParameter) continue;
            if (scan.op == .Variable and scan.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(scan.words[3]);
                if (sc == .Function) {
                    const vid = scan.words[2];
                    if (si + 1 < m.instructions.len) {
                        const next = m.instructions[si + 1];
                        if (next.op == .Store and next.words.len >= 3 and next.words[1] == vid) {
                            const sv = next.words[2];
                            for (param_ids.items) |pid| {
                                if (pid == sv) {
                                    out_param_var_ids.put(pid, vid) catch {};
                                    const pn = names.get(pid) orelse "p";
                                    const pa = alloc.dupe(u8, pn) catch continue;
                                    if (names.fetchPut(vid, pa) catch null) |old| alloc.free(old.value);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            if (scan.op != .Variable and scan.op != .Store) break;
        }
    }

    // Call-site out-param detection
    if (opi.get(func_id)) |ois| {
        for (ois.items) |pi| {
            if (pi >= param_ids.items.len) continue;
            const pid = param_ids.items[pi];
            if (out_param_var_ids.contains(pid)) continue;
            const p_inst = getDef(m, pid) orelse continue;
            const ptid = p_inst.words[1];
            var si2 = func_idx + 1;
            while (si2 < m.instructions.len) : (si2 += 1) {
                const si = m.instructions[si2];
                if (si.op == .FunctionEnd) break;
                if (si.op != .Variable or si.words.len < 4) continue;
                const sc: spirv.StorageClass = @enumFromInt(si.words[3]);
                if (sc != .Function) continue;
                const vid = si.words[2];
                const vti = getDef(m, si.words[1]);
                if (vti) |vt| {
                    if (vt.op == .TypePointer and vt.words.len > 3 and vt.words[3] == ptid) {
                        out_param_var_ids.put(pid, vid) catch {};
                        const pn = names.get(pid) orelse "p";
                        const pa = alloc.dupe(u8, pn) catch continue;
                        if (names.fetchPut(vid, pa) catch null) |old| alloc.free(old.value);
                        break;
                    }
                }
            }
        }
    }

    // For MSL entry: emit wrapper that calls helper
    if (is_entry and is_frag) {
        // Emit the helper function (mainImage etc.)
        try w.writeAll("static inline __attribute__((always_inline))\n");

        // Determine return type and params
        var output_var_id: ?u32 = null;
        for (m.instructions) |inst| {
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Output) output_var_id = inst.words[2];
            }
        }

        // Helper function signature: void mainImage(thread float4& out, float2 fragCoord, ...)
        try w.writeAll("void ");
        try w.writeAll(func_name);
        try w.writeAll("_impl(");

        var first_param = true;

        // Add output param (thread float4&)
        if (output_var_id) |ovid| {
            const on = names.get(ovid) orelse "_fragColor";
            try w.print("thread float4& {s}", .{on});
            first_param = false;
        }

        // Add frag coord param
        if (output_var_id != null) {
            try w.writeAll(", float2 _fragCoord");
        } else {
            try w.writeAll("float2 _fragCoord");
            first_param = false;
        }

        // Add cbuffer params
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("constant {s}& {s}_1", .{cb.name, cb.name});
            first_param = false;
        }

        // Add texture + sampler params
        for (textures.items) |tex| {
            if (!first_param) try w.writeAll(", ");
            try w.print("texture2d<float> {s}", .{tex.name});
            try w.print(", sampler {s}Smplr", .{tex.name});
            first_param = false;
        }

        try w.writeAll(")\n{\n");
        try emitBody(m, names, decs, func_idx, w, alloc, is_frag, output_var_id);
        try w.writeAll("}\n\n");

        // Now emit the entry wrapper
        try w.writeAll("fragment main0_out ");
        try w.writeAll(func_name);
        try w.writeAll("(");

        first_param = true;
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("constant {s}& {s}_1 [[buffer({d})]]", .{cb.name, cb.name, cb.binding});
            first_param = false;
        }
        for (textures.items) |tex| {
            if (!first_param) try w.writeAll(", ");
            try w.print("texture2d<float> {s} [[texture({d})]]", .{tex.name, tex.binding});
            try w.print(", sampler {s}Smplr [[sampler({d})]]", .{tex.name, tex.binding});
            first_param = false;
        }
        if (!first_param) try w.writeAll(", ");
        try w.writeAll("float4 gl_FragCoord [[position]])");

        try w.writeAll("\n{\n    main0_out out = {};\n    ");
        try w.print("{s}_impl(out._fragColor, gl_FragCoord.xy", .{func_name});
        for (cbuffers.items) |cb| {
            try w.print(", {s}_1", .{cb.name});
        }
        for (textures.items) |tex| {
            try w.print(", {s}, {s}Smplr", .{tex.name, tex.name});
        }
        try w.writeAll(");\n    return out;\n}\n");
        return;
    }

    // Compute kernel entry point
    if (is_entry and is_compute) {
        try w.writeAll("kernel void ");
        try w.writeAll(func_name);
        try w.writeAll("(");

        var first_param = true;

        // Emit storage buffers as device pointers
        for (storage_buffers.items) |sb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("device {s}* {s} [[buffer({d})]]", .{sb.name, sb.name, sb.binding});
            first_param = false;
        }

        // Emit uniform buffers
        for (cbuffers.items) |cb| {
            if (!first_param) try w.writeAll(", ");
            try w.print("constant {s}& {s}_1 [[buffer({d})]]", .{cb.name, cb.name, cb.binding});
            first_param = false;
        }

        // Thread position
        if (!first_param) try w.writeAll(", ");
        try w.writeAll("uint3 gl_GlobalInvocationID [[thread_position_in_grid]]");

        try w.writeAll(")\n{\n");

        // Emit workgroup (shared) variables
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .Variable and inst.words.len >= 4) {
                const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
                if (sc == .Workgroup) {
                    const ri = inst.words[2];
                    const tn = try mslType(m, inst.words[1], names, alloc);
                    try w.print("    threadgroup {s} {s};\n", .{tn, names.get(ri) orelse "shared_var"});
                }
            }
        }

        try emitBody(m, names, decs, func_idx, w, alloc, false, null);
        try w.writeAll("}\n");
        return;
    }

    // Non-entry function
    if (std.mem.eql(u8, rt, "void")) {
        try w.print("void {s}(", .{func_name});
    } else {
        try w.print("{s} {s}(", .{rt, func_name});
    }

    for (param_ids.items, 0..) |pid, i| {
        if (i > 0) try w.writeAll(", ");
        const pi = getDef(m, pid).?;
        const pn = names.get(pid) orelse "p";
        const pti = getDef(m, pi.words[1]);
        var is_out = false;
        var itid = pi.words[1];
        if (pti) |pt| {
            if (pt.op == .TypePointer and pt.words.len > 3) {
                is_out = true;
                itid = pt.words[3];
            }
        }
        if (out_param_var_ids.contains(pid)) {
            is_out = true;
        }
        if (!is_out) {
            if (opi.get(func_id)) |oindices| {
                for (oindices.items) |oi| {
                    if (oi == i) { is_out = true; break; }
                }
            }
        }
        const pt2 = try mslType(m, itid, names, alloc);
        if (is_out) {
            try w.print("thread {s}& {s}", .{pt2, pn});
        } else {
            try w.print("{s} {s}", .{pt2, pn});
        }
    }

    try w.writeAll(")\n{\n");
    try emitBody(m, names, decs, func_idx, w, alloc, false, null);
    try w.writeAll("}\n");
}

// ---- Body/Block/Instruction emission (same structure as GLSL backend) ----

fn emitBody(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    func_idx: usize,
    w: anytype,
    alloc: std.mem.Allocator,
    is_frag: bool,
    output_var_id: ?u32,
) !void {
    var label_map = std.AutoHashMap(u32, usize).init(alloc);
    defer label_map.deinit();
    { var idx = func_idx + 1; while (idx < m.instructions.len) : (idx += 1) { const inst = m.instructions[idx]; if (inst.op == .FunctionEnd) break; if (inst.op == .Label and inst.words.len > 1) label_map.put(inst.words[1], idx) catch {}; } }

    var bc_merge = std.AutoHashMap(usize, u32).init(alloc);
    defer bc_merge.deinit();
    {
        var idx = func_idx + 1;
        while (idx < m.instructions.len) : (idx += 1) {
            const inst = m.instructions[idx];
            if (inst.op == .FunctionEnd) break;
            if (inst.op == .SelectionMerge and inst.words.len > 1) {
                const ml = inst.words[1];
                { var j = idx + 1; while (j < m.instructions.len) : (j += 1) { const n = m.instructions[j]; if (n.op == .BranchConditional) { bc_merge.put(j, ml) catch {}; break; } if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break; if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break; } }
                { var k = idx + 1; while (k < m.instructions.len) : (k += 1) { const n = m.instructions[k]; if (n.op == .Switch) { bc_merge.put(k, ml) catch {}; break; } if (n.op == .Branch or n.op == .ReturnValue or n.op == .Return or n.op == .Kill) break; if (n.op != .Label and n.op != .SelectionMerge and n.op != .LoopMerge) break; } }
            }
        }
    }

    var idx = func_idx + 1;
    while (idx < m.instructions.len) : (idx += 1) {
        const inst = m.instructions[idx];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .FunctionParameter or inst.op == .Label or inst.op == .SelectionMerge or inst.op == .LoopMerge or inst.op == .Branch) continue;

        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                const he = fl != null and fl.? != mval;
                try w.print("    if ({s})\n    {{\n", .{cn});
                idx = try emitBlock(m, names, decs, tl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                if (he) {
                    try w.writeAll("    } else {\n");
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                try w.print("    if ({s}) {{ /* TODO */ }}\n", .{cn});
            }
            continue;
        }

        if (inst.op == .Switch) {
            if (inst.words.len < 3) continue;
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                try w.print("    switch ({s}) {{\n", .{sn});
                if (dl != mval) {
                    try w.writeAll("    default:\n");
                    _ = try emitBlock(m, names, decs, dl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == mval) continue;
                    try w.print("    case {d}:\n", .{cv});
                    _ = try emitBlock(m, names, decs, target, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                try w.writeAll("    }\n");
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                try w.writeAll("    // switch TODO\n");
            }
            continue;
        }

        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, output_var_id);
    }
}

fn emitBlock(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    label: u32, merge_label: u32,
    lm: *const std.AutoHashMap(u32, usize),
    bm: *const std.AutoHashMap(usize, u32),
    w: anytype, alloc: std.mem.Allocator,
    is_frag: bool, ovid: ?u32, indent: []const u8,
) !usize {
    const si = lm.get(label) orelse return error.InvalidSpirv;
    var i: usize = si + 1;
    while (i < m.instructions.len) : (i += 1) {
        const inst = m.instructions[i];
        if (inst.op == .FunctionEnd) break;
        if (inst.op == .Branch and inst.words.len > 1 and inst.words[1] == merge_label) break;
        if (inst.op == .Label or inst.op == .SelectionMerge or inst.op == .LoopMerge) continue;
        if (inst.op == .Branch) continue;
        if (inst.op == .BranchConditional) {
            if (inst.words.len < 4) continue;
            const cn = names.get(inst.words[1]) orelse "c";
            const tl = inst.words[2];
            const fl = if (inst.words.len > 3) inst.words[3] else null;
            const nm = bm.get(i);
            if (nm) |nmv| {
                const he = fl != null and fl.? != nmv;
                try w.print("{s}    if ({s})\n{s}    {{\n", .{indent, cn, indent});
                i = try emitBlock(m, names, decs, tl, nmv, lm, bm, w, alloc, is_frag, ovid, indent);
                if (he) {
                    try w.print("{s}    }} else {{\n", .{indent});
                    i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent);
                }
                try w.print("{s}    }}\n", .{indent});
                if (lm.get(nmv)) |nmi| { i = nmi; }
            } else {
                try w.print("{s}    if ({s}) {{ /* */ }}\n", .{indent, cn});
            }
            continue;
        }
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
    }
    return i;
}

// ---- Instruction emission (MSL dialect) ----
// Most instructions are identical to GLSL; key differences:
// - Types: float4/float3/float2 instead of vec4/vec3/vec2
// - Texture: tex.sample(samp, uv) instead of texture(tex, uv)
// - Uniforms: Globals_1._m0 instead of Globals_m0
// - powr instead of pow, fast::clamp instead of clamp

fn emitInstruction(
    m: *const ParsedModule,
    names: *std.AutoHashMap(u32, []const u8),
    decs: *const std.AutoHashMap(u32, std.ArrayList(DecorationEntry)),
    inst: Instruction,
    w: anytype, alloc: std.mem.Allocator,
    is_frag: bool, ovid: ?u32,
) !void {
    _ = decs;
    switch (inst.op) {
        .Variable => {
            if (inst.words.len < 4) return;
            const sc: spirv.StorageClass = @enumFromInt(inst.words[3]);
            if (sc == .Output and is_frag) {
                const ri = inst.words[2];
                const tn = try mslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s};\n", .{tn, names.get(ri) orelse "var"});
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant or sc == .Workgroup) return;
            const ri = inst.words[2];
            const tn = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s};\n", .{tn, names.get(ri) orelse "var"});
        },
        .Load => {
            const rn = names.get(inst.words[2]) orelse "v";
            const pid = inst.words[3];
            const pn = names.get(pid) orelse "var";
            const pi = getDef(m, pid);
            var is_special = false;
            if (pi) |p| {
                if (p.op == .Variable and p.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(p.words[3]);
                    if (sc == .UniformConstant or sc == .Output or sc == .Input) is_special = true;
                }
            }
            if (is_special) {
                const a = try alloc.dupe(u8, pn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                const rtt = try mslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = ", .{rtt, rn});
                try writeResolvePointer(m, names, pid, w);
                try w.writeAll(";\n");
            }
        },
        .Store => {
            if (inst.words.len < 3) return;
            const on = names.get(inst.words[2]) orelse "0";
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], w);
            try w.print(" = {s};\n", .{on});
        },
        .CopyObject => {
            if (inst.words.len < 4) return;
            const sn = names.get(inst.words[3]) orelse "0";
            const a = try alloc.dupe(u8, sn);
            if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
        },
        .CopyMemory => {
            if (inst.words.len < 3) return;
            try w.writeAll("    ");
            try writeResolvePointer(m, names, inst.words[1], w);
            try w.writeAll(" = ");
            try writeResolvePointer(m, names, inst.words[2], w);
            try w.writeAll(";\n");
        },
        .Phi => {
            if (inst.words.len < 4) return;
            const fv = inst.words[3];
            if (names.get(fv)) |sn| {
                const a = try alloc.dupe(u8, sn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                const a = try std.fmt.allocPrint(alloc, "v{d}", .{fv});
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            }
        },
        .AccessChain => {
            const ri = inst.words[2];
            const bi = inst.words[3];
            const ex = try buildAccessExpr(m, names, bi, inst.words[4..], alloc);
            if (names.fetchPut(ri, ex) catch null) |old| alloc.free(old.value);
        },
        .FAdd, .IAdd => try emitBinOp(m, names, inst, "+", w, alloc),
        .FSub, .ISub => try emitBinOp(m, names, inst, "-", w, alloc),
        .FMul, .IMul => try emitBinOp(m, names, inst, "*", w, alloc),
        .FDiv, .SDiv, .UDiv => try emitBinOp(m, names, inst, "/", w, alloc),
        .FMod, .UMod, .SRem, .FRem => try emitBinOp(m, names, inst, "%", w, alloc),
        .FNegate, .SNegate => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\n", .{rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0"});
        },
        .VectorTimesScalar, .MatrixTimesScalar, .VectorTimesMatrix, .MatrixTimesVector, .MatrixTimesMatrix => try emitBinOp(m, names, inst, "*", w, alloc),
        .Dot => try emitCall(m, names, inst, "dot", w, alloc),
        .Transpose => try emitCall(m, names, inst, "transpose", w, alloc),
        .FOrdEqual, .IEqual => try emitBinOp(m, names, inst, "==", w, alloc),
        .FOrdNotEqual, .INotEqual => try emitBinOp(m, names, inst, "!=", w, alloc),
        .FOrdLessThan, .SLessThan, .ULessThan => try emitBinOp(m, names, inst, "<", w, alloc),
        .FOrdGreaterThan, .SGreaterThan, .UGreaterThan => try emitBinOp(m, names, inst, ">", w, alloc),
        .FOrdLessThanEqual, .SLessThanEqual, .ULessThanEqual => try emitBinOp(m, names, inst, "<=", w, alloc),
        .FOrdGreaterThanEqual, .SGreaterThanEqual, .UGreaterThanEqual => try emitBinOp(m, names, inst, ">=", w, alloc),
        .LogicalOr => try emitBinOp(m, names, inst, "||", w, alloc),
        .LogicalAnd => try emitBinOp(m, names, inst, "&&", w, alloc),
        .LogicalNot => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\n", .{rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0"});
        },
        .Select => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s}) ? {s} : {s};\n", .{
                rtt, names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "c",
                names.get(inst.words[4]) orelse "t",
                names.get(inst.words[5]) orelse "f",
            });
        },
        .BitwiseOr => try emitBinOp(m, names, inst, "|", w, alloc),
        .BitwiseXor => try emitBinOp(m, names, inst, "^", w, alloc),
        .BitwiseAnd => try emitBinOp(m, names, inst, "&", w, alloc),
        .ShiftRightLogical, .ShiftRightArithmetic => try emitBinOp(m, names, inst, ">>", w, alloc),
        .ShiftLeftLogical => try emitBinOp(m, names, inst, "<<", w, alloc),
        .Not => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ~{s};\n", .{rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0"});
        },
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU, .UConvert, .SConvert, .FConvert, .Bitcast => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}({s});\n", .{rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0"});
        },
        .CompositeConstruct => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}(", .{rtt, names.get(inst.words[2]) orelse "v", rtt});
            for (inst.words[3..], 0..) |cid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(cid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        .CompositeExtract => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{rtt, names.get(inst.words[2]) orelse "v", comp});
            for (inst.words[4..]) |index| {
                try w.print("[{d}]", .{index});
            }
            try w.writeAll(";\n");
        },
        .VectorShuffle => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "v1";
            const v2 = names.get(inst.words[4]) orelse "v2";
            try w.print("    {s} {s} = {s}(", .{rtt, names.get(inst.words[2]) orelse "v", rtt});
            for (inst.words[5..], 0..) |sel, i| {
                if (i > 0) try w.writeAll(", ");
                // In MSL, use component access
                if (sel < 4) {
                    try w.print("{s}[{d}]", .{v1, sel});
                } else {
                    try w.print("{s}[{d}]", .{v2, sel - 4});
                }
            }
            try w.writeAll(");\n");
        },
        .DPdx, .DPdxFine, .DPdxCoarse => try emitCall(m, names, inst, "dfdx", w, alloc),
        .DPdy, .DPdyFine, .DPdyCoarse => try emitCall(m, names, inst, "dfdy", w, alloc),
        .Fwidth, .FwidthFine, .FwidthCoarse => try emitCall(m, names, inst, "fwidth", w, alloc),
        .All => try emitCall(m, names, inst, "all", w, alloc),
        .Any => try emitCall(m, names, inst, "any", w, alloc),
        .ExtInst => {
            if (inst.words.len < 5) return;
            try emitStd450(m, names, inst, inst.words[4], w, alloc);
        },
        .SampledImage => {
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
        },
        .OpImage => {
            // OpImage extracts image from sampled_image — in MSL, texture is already separate
            const ri = inst.words[2];
            const iname = names.get(inst.words[3]) orelse "tex";
            const a = try alloc.dupe(u8, iname);
            if (names.fetchPut(ri, a) catch null) |old| alloc.free(old.value);
        },
        .ImageSampleImplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // MSL: tex.sample(samp, coord)
            try w.print("    {s} {s} = {s}.sample({s}Smplr, {s});\n", .{rtt, names.get(inst.words[2]) orelse "v", si, si, coord});
        },
        .ImageSampleProjImplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            // Projected sample: divide xy by w
            try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}.xy / {s}.w);\n", .{rtt, names.get(inst.words[2]) orelse "v", si, si, coord, coord});
        },
        .ImageSampleExplicitLod => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level({s}));\n", .{rtt, names.get(inst.words[2]) orelse "v", si, si, coord, names.get(inst.words[off]) orelse "0"});
                } else {
                    try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level(0));\n", .{rtt, names.get(inst.words[2]) orelse "v", si, si, coord});
                }
            } else {
                try w.print("    {s} {s} = {s}.sample({s}Smplr, {s}, level(0));\n", .{rtt, names.get(inst.words[2]) orelse "v", si, si, coord});
            }
        },
        .ImageFetch => {
            const rtt = try mslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            try w.print("    {s} {s} = {s}.read({s});\n", .{rtt, names.get(inst.words[2]) orelse "v", si, names.get(inst.words[4]) orelse "0"});
        },
        .Kill => try w.writeAll("    discard_fragment();\n"),
        .ControlBarrier => {
            try w.writeAll("    threadgroup_barrier(mem_flags::mem_threadgroup);\n");
        },
        .MemoryBarrier => {
            try w.writeAll("    threadgroup_barrier(mem_flags::mem_device);\n");
        },
        .Return => {
            if (!(is_frag and ovid != null)) try w.writeAll("    return;\n");
        },
        .ReturnValue => {
            const vid = inst.words[1];
            if (!(is_frag and ovid != null and vid == ovid.?)) {
                try w.print("    return {s};\n", .{names.get(vid) orelse "0"});
            }
        },
        .FunctionCall => {
            const cfid = inst.words[3];
            const cfn = names.get(cfid) orelse "func";
            const rn = names.get(inst.words[2]) orelse "v";
            const rti = inst.words[1];
            const is_void = blk: {
                const r = getDef(m, rti);
                break :blk r != null and r.?.op == .TypeVoid;
            };
            if (is_void) {
                try w.print("    {s}(", .{cfn});
            } else {
                const rtt = try mslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}(", .{rtt, rn, cfn});
            }
            for (inst.words[4..], 0..) |aid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(aid) orelse "0");
            }
            try w.writeAll(");\n");
        },
        else => {
            try w.print("    // unhandled op {d}\n", .{@intFromEnum(inst.op)});
        },
    }
}

fn emitBinOp(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try mslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s} {s} {s};\n", .{rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "a", op, names.get(inst.words[4]) orelse "b"});
}

fn emitCall(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try mslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s}(", .{rtt, names.get(inst.words[2]) orelse "v", func});
    for (inst.words[3..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}

fn emitStd450(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, instruction: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try mslType(m, inst.words[1], names, alloc);
    const func = std450ToMsl(instruction) orelse {
        try w.print("    // unhandled std450 #{d}\n", .{instruction});
        return;
    };
    try w.print("    {s} {s} = {s}(", .{rtt, names.get(inst.words[2]) orelse "v", func});
    for (inst.words[5..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\n");
}
