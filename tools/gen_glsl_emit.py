#!/usr/bin/env python3
"""Generate the emit functions for spirv_to_glsl.zig"""
import os

parts = []

# emitBody
parts.append("""
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
                try w.print("    if ({s})\\n    {{\\n", .{cn});
                idx = try emitBlock(m, names, decs, tl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                if (he) {
                    try w.writeAll("    } else {\\n");
                    idx = try emitBlock(m, names, decs, fl.?, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                try w.writeAll("    }\\n");
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                try w.print("    if ({s}) {{ /* TODO */ }}\\n", .{cn});
            }
            continue;
        }

        if (inst.op == .Switch) {
            if (inst.words.len < 3) continue;
            const sn = names.get(inst.words[1]) orelse "s";
            const dl = inst.words[2];
            const ml = bc_merge.get(idx);
            if (ml) |mval| {
                try w.print("    switch ({s}) {{\\n", .{sn});
                if (dl != mval) {
                    try w.writeAll("    default:\\n");
                    _ = try emitBlock(m, names, decs, dl, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                var wi: usize = 3;
                while (wi + 1 < inst.words.len) : (wi += 2) {
                    const cv = inst.words[wi];
                    const target = inst.words[wi + 1];
                    if (target == mval) continue;
                    try w.print("    case {d}:\\n", .{cv});
                    _ = try emitBlock(m, names, decs, target, mval, &label_map, &bc_merge, w, alloc, is_frag, output_var_id, "    ");
                }
                try w.writeAll("    }\\n");
                if (label_map.get(mval)) |mi| { idx = mi; }
            } else {
                try w.writeAll("    // switch TODO\\n");
            }
            continue;
        }

        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, output_var_id);
    }
}
""")

# emitBlock
parts.append("""
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
                try w.print("{s}    if ({s})\\n{s}    {{\\n", .{ indent, cn, indent });
                i = try emitBlock(m, names, decs, tl, nmv, lm, bm, w, alloc, is_frag, ovid, indent);
                if (he) {
                    try w.print("{s}    }} else {{\\n", .{indent});
                    i = try emitBlock(m, names, decs, fl.?, nmv, lm, bm, w, alloc, is_frag, ovid, indent);
                }
                try w.print("{s}    }}\\n", .{indent});
                if (lm.get(nmv)) |nmi| { i = nmi; }
            } else {
                try w.print("{s}    if ({s}) {{ /* */ }}\\n", .{ indent, cn });
            }
            continue;
        }
        try emitInstruction(m, names, decs, inst, w, alloc, is_frag, ovid);
    }
    return i;
}
""")

# emitInstruction (GLSL dialect)
parts.append("""
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
                const tn = try glslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s};\\n", .{ tn, names.get(ri) orelse "var" });
                return;
            }
            if (sc == .Input or sc == .Output or sc == .Uniform or sc == .UniformConstant) return;
            const ri = inst.words[2];
            const tn = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s};\\n", .{ tn, names.get(ri) orelse "var" });
        },
        .Load => {
            const rn = names.get(inst.words[2]) orelse "v";
            const pid = inst.words[3];
            const pn = names.get(pid) orelse "var";
            const pi = getDef(m, pid);
            var is_tex = false;
            var is_oload = false;
            if (pi) |p| {
                if (p.op == .Variable and p.words.len >= 4) {
                    const sc: spirv.StorageClass = @enumFromInt(p.words[3]);
                    if (sc == .UniformConstant) {
                        const pt = getDef(m, p.words[1]);
                        if (pt) |ptv| {
                            if (ptv.op == .TypePointer and ptv.words.len > 3) {
                                const pe = getDef(m, ptv.words[3]);
                                if (pe) |pev| {
                                    if (pev.op == .TypeSampler or pev.op == .TypeSampledImage or pev.op == .TypeImage) is_tex = true;
                                }
                            }
                        }
                    }
                    if (sc == .Output and is_frag) is_oload = true;
                    if (sc == .Input and is_frag) is_oload = true;
                }
            }
            if (is_oload or is_tex) {
                const a = try alloc.dupe(u8, pn);
                if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
            } else {
                const rtt = try glslType(m, inst.words[1], names, alloc);
                const pe = try resolvePointer(m, names, pid, alloc);
                try w.print("    {s} {s} = {s};\\n", .{ rtt, rn, pe });
                alloc.free(pe);
            }
        },
        .Store => {
            if (inst.words.len < 3) return;
            const pe = try resolvePointer(m, names, inst.words[1], alloc);
            const on = names.get(inst.words[2]) orelse "0";
            try w.print("    {s} = {s};\\n", .{ pe, on });
            alloc.free(pe);
        },
        .CopyObject => {
            if (inst.words.len < 4) return;
            const sn = names.get(inst.words[3]) orelse "0";
            const a = try alloc.dupe(u8, sn);
            if (names.fetchPut(inst.words[2], a) catch null) |old| alloc.free(old.value);
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
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = -{s};\\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
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
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = !{s};\\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .Select => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ({s}) ? {s} : {s};\\n", .{
                rtt, names.get(inst.words[2]) orelse "v",
                names.get(inst.words[3]) orelse "c",
                names.get(inst.words[4]) orelse "t",
                names.get(inst.words[5]) orelse "f",
            });
        },
        .BitwiseOr => try emitBinOp(m, names, inst, "|", w, alloc),
        .BitwiseXor => try emitBinOp(m, names, inst, "^", w, alloc),
        .BitwiseAnd => try emitBinOp(m, names, inst, "&", w, alloc),
        .Not => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = ~{s};\\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "0" });
        },
        .ConvertSToF, .ConvertUToF, .ConvertFToS, .ConvertFToU, .UConvert, .SConvert, .FConvert, .Bitcast => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}({s});\\n", .{ rtt, names.get(inst.words[2]) orelse "v", rtt, names.get(inst.words[3]) orelse "0" });
        },
        .CompositeConstruct => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[3..], 0..) |cid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(cid) orelse "0");
            }
            try w.writeAll(");\\n");
        },
        .CompositeExtract => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const comp = names.get(inst.words[3]) orelse "c";
            try w.print("    {s} {s} = {s}", .{ rtt, names.get(inst.words[2]) orelse "v", comp });
            const pt = getTypeOf(m, inst.words[3]);
            const is_vec = if (pt) |ptv| blk: {
                const pti = getDef(m, ptv);
                break :blk pti != null and pti.?.op == .TypeVector;
            } else false;
            for (inst.words[4..]) |index| {
                if (is_vec) {
                    try w.writeAll(swizzleChar(index));
                } else {
                    try w.print("[{d}]", .{index});
                }
            }
            try w.writeAll(";\\n");
        },
        .VectorShuffle => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const v1 = names.get(inst.words[3]) orelse "v1";
            const v2 = names.get(inst.words[4]) orelse "v2";
            const v1t = getTypeOf(m, inst.words[3]);
            const v1l: u32 = if (v1t) |vt| blk: {
                const vi = getDef(m, vt);
                break :blk if (vi != null and vi.?.op == .TypeVector) vi.?.words[3] else 4;
            } else 4;
            try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", rtt });
            for (inst.words[5..], 0..) |sel, i| {
                if (i > 0) try w.writeAll(", ");
                if (sel < v1l) {
                    try w.print("{s}{s}", .{ v1, swizzleChar(sel) });
                } else {
                    try w.print("{s}{s}", .{ v2, swizzleChar(sel - v1l) });
                }
            }
            try w.writeAll(");\\n");
        },
        .DPdx, .DPdxFine, .DPdxCoarse => try emitCall(m, names, inst, "dFdx", w, alloc),
        .DPdy, .DPdyFine, .DPdyCoarse => try emitCall(m, names, inst, "dFdy", w, alloc),
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
        .ImageSampleImplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            try w.print("    {s} {s} = texture({s}, {s});\\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
        },
        .ImageSampleExplicitLod => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            const si = names.get(inst.words[3]) orelse "tex";
            const coord = names.get(inst.words[4]) orelse "uv";
            if (inst.words.len > 5) {
                const mask = inst.words[5];
                var off: usize = 6;
                if (mask & 0x1 != 0) off += 1;
                if (mask & 0x2 != 0 and off < inst.words.len) {
                    try w.print("    {s} {s} = textureLod({s}, {s}, {s});\\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[off]) orelse "0" });
                } else if (mask & 0x4 != 0 and off + 1 < inst.words.len) {
                    try w.print("    {s} {s} = textureGrad({s}, {s}, {s}, {s});\\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord, names.get(inst.words[off]) orelse "0", names.get(inst.words[off + 1]) orelse "0" });
                } else {
                    try w.print("    {s} {s} = textureLod({s}, {s}, 0);\\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
                }
            } else {
                try w.print("    {s} {s} = textureLod({s}, {s}, 0);\\n", .{ rtt, names.get(inst.words[2]) orelse "v", si, coord });
            }
        },
        .ImageFetch => {
            const rtt = try glslType(m, inst.words[1], names, alloc);
            try w.print("    {s} {s} = texelFetch({s}, {s}, 0);\\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "tex", names.get(inst.words[4]) orelse "0" });
        },
        .Kill => try w.writeAll("    discard;\\n"),
        .Return => {
            if (!(is_frag and ovid != null)) try w.writeAll("    return;\\n");
        },
        .ReturnValue => {
            const vid = inst.words[1];
            if (!(is_frag and ovid != null and vid == ovid.?)) {
                try w.print("    return {s};\\n", .{names.get(vid) orelse "0"});
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
                const rtt = try glslType(m, inst.words[1], names, alloc);
                try w.print("    {s} {s} = {s}(", .{ rtt, rn, cfn });
            }
            for (inst.words[4..], 0..) |aid, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(names.get(aid) orelse "0");
            }
            try w.writeAll(");\\n");
        },
        else => {
            try w.print("    // unhandled op {d}\\n", .{@intFromEnum(inst.op)});
        },
    }
}

fn emitBinOp(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, op: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s} {s} {s};\\n", .{ rtt, names.get(inst.words[2]) orelse "v", names.get(inst.words[3]) orelse "a", op, names.get(inst.words[4]) orelse "b" });
}

fn emitCall(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, func: []const u8, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[3..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\\n");
}

fn emitStd450(m: *const ParsedModule, names: *std.AutoHashMap(u32, []const u8), inst: Instruction, instruction: u32, w: anytype, alloc: std.mem.Allocator) !void {
    const rtt = try glslType(m, inst.words[1], names, alloc);
    const func = std450ToGlsl(instruction) orelse {
        try w.print("    // unhandled std450 #{d}\\n", .{instruction});
        return;
    };
    try w.print("    {s} {s} = {s}(", .{ rtt, names.get(inst.words[2]) orelse "v", func });
    for (inst.words[5..], 0..) |arg, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(names.get(arg) orelse "x");
    }
    try w.writeAll(");\\n");
}
""")

# Write to a temp file
content = '\n'.join(parts)
with open('src/spirv_to_glsl_emit_part.zig', 'w') as f:
    f.write(content)
