// SPDX-License-Identifier: MIT OR Apache-2.0
/// optimizeMatVecMul: Detect extract -> VecTimesScalar -> FAdd chains implementing
/// matrix-vector multiplication, replace with OpMatrixTimesVector.
const std = @import("std");

pub fn optimizeMatVecMul(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build instruction maps
    var extract_src = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer extract_src.deinit(alloc);
    var extract_idx = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer extract_idx.deinit(alloc);
    var vts_vec = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer vts_vec.deinit(alloc);
    var vts_scalar = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer vts_scalar.deinit(alloc);
    var vts_type = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer vts_type.deinit(alloc);
    var fadd_a = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer fadd_a.deinit(alloc);
    var fadd_b = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer fadd_b.deinit(alloc);
    var use_count = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer use_count.deinit(alloc);
    var float_const_val = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer float_const_val.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 81 and wc == 5) {
            try extract_src.put(alloc, words[pos + 2], words[pos + 3]);
            try extract_idx.put(alloc, words[pos + 2], words[pos + 4]);
        } else if (opcode == 142 and wc == 5) {
            try vts_type.put(alloc, words[pos + 2], words[pos + 1]);
            try vts_vec.put(alloc, words[pos + 2], words[pos + 3]);
            try vts_scalar.put(alloc, words[pos + 2], words[pos + 4]);
        } else if (opcode == 129 and wc == 5) {
            try fadd_a.put(alloc, words[pos + 2], words[pos + 3]);
            try fadd_b.put(alloc, words[pos + 2], words[pos + 4]);
        } else if (opcode == 43 and wc >= 4) {
            try float_const_val.put(alloc, words[pos + 2], words[pos + 3]);
        }

        var i: u32 = 1;
        while (i < wc) : (i += 1) {
            if (i == 2) continue;
            const uid = words[pos + i];
            if (uid > 0 and uid < bound) {
                const gop = try use_count.getOrPut(alloc, uid);
                if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
            }
        }
        pos = ie;
    }

    // Phase 2: Find mat*vec chains
    const ExtInfo = struct { rid: u32, idx: u32 };
    var src_groups = std.AutoHashMapUnmanaged(u32, std.ArrayList(ExtInfo)){};
    defer {
        var dit = src_groups.iterator();
        while (dit.next()) |e| e.value_ptr.deinit(alloc);
        src_groups.deinit(alloc);
    }

    var eit = extract_src.iterator();
    while (eit.next()) |e| {
        const rid = e.key_ptr.*;
        const src = e.value_ptr.*;
        const idx = extract_idx.get(rid) orelse continue;
        const gop = try src_groups.getOrPut(alloc, src);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(ExtInfo).initCapacity(alloc, 4) catch continue;
        try gop.value_ptr.append(alloc, .{ .rid = rid, .idx = idx });
    }

    const Chain = struct {
        source: u32,
        result_type: u32,
        ext_ids: [4]u32,
        vts_ids: [4]u32,
        row_ids: [4]u32,
        fadd_ids: [4]u32,
        num_rows: u32,
        num_fadds: u32,
        float_1_id: u32,
        final_result_id: u32,
    };

    var chains = std.ArrayList(Chain).initCapacity(alloc, 4) catch return words;
    defer chains.deinit(alloc);

    var to_remove = std.AutoHashMapUnmanaged(u32, void).empty;
    defer to_remove.deinit(alloc);

    var sit = src_groups.iterator();
    while (sit.next()) |entry| {
        const src = entry.key_ptr.*;
        const exts = entry.value_ptr.items;
        if (exts.len < 3) continue;

        // Sort by index (simple bubble sort)
        for (0..exts.len) |j| {
            for (0..exts.len - 1 - j) |k| {
                if (exts[k].idx > exts[k + 1].idx) {
                    const tmp = exts[k];
                    exts[k] = exts[k + 1];
                    exts[k + 1] = tmp;
                }
            }
        }

        // Check sequential indices
        var sequential = true;
        for (exts, 0..) |e, i| {
            if (e.idx != i) { sequential = false; break; }
        }
        if (!sequential) continue;

        // For each extract, find VTS using it as scalar
        var chain_exts: [4]u32 = .{0} ** 4;
        var chain_vts: [4]u32 = .{0} ** 4;
        var chain_rows: [4]u32 = .{0} ** 4;
        var result_type: u32 = 0;
        var num_rows: u32 = 0;
        var all_ok = true;

        for (exts) |e| {
            if (num_rows >= 4) { all_ok = false; break; }
            if ((use_count.get(e.rid) orelse 0) != 1) { all_ok = false; break; }

            var found = false;
            var vit = vts_scalar.iterator();
            while (vit.next()) |ve| {
                if (ve.value_ptr.* == e.rid) {
                    const vid = ve.key_ptr.*;
                    const rt = vts_type.get(vid) orelse 0;
                    if (result_type == 0) result_type = rt;
                    chain_exts[num_rows] = e.rid;
                    chain_vts[num_rows] = vid;
                    chain_rows[num_rows] = vts_vec.get(vid) orelse 0;
                    num_rows += 1;
                    found = true;
                    break;
                }
            }
            if (!found) { all_ok = false; break; }
        }

        if (!all_ok or num_rows < 3) continue;

        // Build set of VTS IDs
        var vts_set = std.AutoHashMapUnmanaged(u32, void).empty;
        defer vts_set.deinit(alloc);
        for (chain_vts[0..num_rows]) |vid| {
            if (vid != 0) try vts_set.put(alloc, vid, {});
        }

        // Find FAdds connecting VTS results
        var fadd_set = std.AutoHashMapUnmanaged(u32, void).empty;
        defer fadd_set.deinit(alloc);

        var changed = true;
        while (changed) {
            changed = false;
            var fit = fadd_a.iterator();
            while (fit.next()) |fe| {
                const fid = fe.key_ptr.*;
                if (fadd_set.contains(fid)) continue;
                const fa = fe.value_ptr.*;
                const fb = fadd_b.get(fid) orelse 0;
                if (vts_set.contains(fa) or vts_set.contains(fb) or fadd_set.contains(fa) or fadd_set.contains(fb)) {
                    try fadd_set.put(alloc, fid, {});
                    changed = true;
                }
            }
        }

        var chain_fadds: [4]u32 = .{0} ** 4;
        var num_fadds: u32 = 0;
        var fsit = fadd_set.iterator();
        while (fsit.next()) |fe| {
            if (num_fadds < 4) {
                chain_fadds[num_fadds] = fe.key_ptr.*;
                num_fadds += 1;
            }
        }

        if (num_fadds < num_rows - 1) continue;

        const final_result_id: u32 = chain_fadds[num_fadds - 1];

        // Check if last FAdd adds an extra (non-multiplied) row
        const extra_row: u32 = blk: {
            if (num_fadds >= num_rows) {
                const lfa = fadd_a.get(final_result_id) orelse 0;
                const lfb = fadd_b.get(final_result_id) orelse 0;
                if (!vts_set.contains(lfa) and !fadd_set.contains(lfa) and lfa != 0) break :blk lfa;
                if (!vts_set.contains(lfb) and !fadd_set.contains(lfb) and lfb != 0) break :blk lfb;
            }
            break :blk 0;
        };

        // Build final row list
        var all_rows: [5]u32 = .{0} ** 5;
        for (0..num_rows) |j| all_rows[j] = chain_rows[j];
        var total_rows = num_rows;
        if (extra_row != 0 and total_rows < 5) {
            all_rows[total_rows] = extra_row;
            total_rows += 1;
        }

        // Find float 1.0
        const one_bits: u32 = @as(u32, @bitCast(@as(f32, 1.0)));
        var float_1_id: u32 = 0;
        var fcit = float_const_val.iterator();
        while (fcit.next()) |fce| {
            if (fce.value_ptr.* == one_bits) {
                float_1_id = fce.key_ptr.*;
                break;
            }
        }
        if (float_1_id == 0) continue;

        var final_rows: [4]u32 = undefined;
        const actual_rows = @min(total_rows, 4);
        for (0..actual_rows) |j| final_rows[j] = all_rows[j];

        try chains.append(alloc, .{
            .source = src,
            .result_type = result_type,
            .ext_ids = chain_exts,
            .vts_ids = chain_vts,
            .row_ids = final_rows,
            .fadd_ids = chain_fadds,
            .num_rows = actual_rows,
            .num_fadds = num_fadds,
            .float_1_id = float_1_id,
            .final_result_id = final_result_id,
        });

        for (chain_exts[0..num_rows]) |id| if (id != 0) try to_remove.put(alloc, id, {});
        for (chain_vts[0..num_rows]) |id| if (id != 0) try to_remove.put(alloc, id, {});
        for (chain_fadds[0..num_fadds]) |id| if (id != 0) try to_remove.put(alloc, id, {});
    }

    if (chains.items.len == 0) return words;

    // Phase 3: Allocate new IDs
    var next_new_id = bound;

    // Check if OpTypeMatrix already exists
    var mat_type_id: u32 = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 25 and wc == 4) {
            const ch0 = chains.items[0];
            if (words[pos + 2] == ch0.result_type and words[pos + 3] == ch0.num_rows) {
                mat_type_id = words[pos + 1];
            }
        }
        pos = ie;
    }

    const need_new_mat_type = (mat_type_id == 0);
    if (need_new_mat_type) {
        mat_type_id = next_new_id;
        next_new_id += 1;
    }

    // Per chain: CC vec4, CC mat, MatVecMul
    const ChainAlloc = struct {
        cc_vec4_id: u32,
        cc_mat_id: u32,
        matmul_id: u32,
    };
    var chain_allocs = std.ArrayList(ChainAlloc).initCapacity(alloc, chains.items.len) catch return words;
    defer chain_allocs.deinit(alloc);

    for (chains.items) |_| {
        const cc_vec4_id = next_new_id;
        next_new_id += 1;
        const cc_mat_id = next_new_id;
        next_new_id += 1;
        const matmul_id = next_new_id;
        next_new_id += 1;
        try chain_allocs.append(alloc, .{
            .cc_vec4_id = cc_vec4_id,
            .cc_mat_id = cc_mat_id,
            .matmul_id = matmul_id,
        });
    }

    // Substitution map
    var subs = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer subs.deinit(alloc);
    for (chains.items, 0..) |ch, ci| {
        try subs.put(alloc, ch.final_result_id, chain_allocs.items[ci].matmul_id);
    }

    // Phase 4: Rewrite
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len * 2);
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, words[0..5]);

    var mat_type_emitted = !need_new_mat_type;

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Insert OpTypeMatrix before first OpFunction
        if (!mat_type_emitted and opcode == 54) {
            const ch0 = chains.items[0];
            try result.append(alloc, (@as(u32, 4) << 16) | 25);
            try result.append(alloc, mat_type_id);
            try result.append(alloc, ch0.result_type);
            try result.append(alloc, ch0.num_rows);
            mat_type_emitted = true;
        }

        const rid = if (wc >= 3) words[pos + 2] else 0;

        // Skip removed instructions
        if ((opcode == 81 or opcode == 142) and to_remove.contains(rid)) {
            pos = ie;
            continue;
        }

        // Check if this FAdd is the chain's final result
        if (opcode == 129 and to_remove.contains(rid)) {
            var is_chain_end = false;
            for (chains.items, 0..) |ch, ci| {
                if (rid == ch.final_result_id) {
                    const ca = chain_allocs.items[ci];
                    // Emit CC vec4(source, 1.0)
                    try result.append(alloc, (@as(u32, 4) << 16) | 80);
                    try result.append(alloc, ch.result_type);
                    try result.append(alloc, ca.cc_vec4_id);
                    try result.append(alloc, ch.source);
                    try result.append(alloc, ch.float_1_id);
                    // Emit CC mat(rows...)
                    const mat_wc: u32 = 3 + ch.num_rows;
                    try result.append(alloc, (@as(u32, mat_wc) << 16) | 80);
                    try result.append(alloc, mat_type_id);
                    try result.append(alloc, ca.cc_mat_id);
                    for (ch.row_ids[0..ch.num_rows]) |row_id| {
                        try result.append(alloc, row_id);
                    }
                    // Emit MatrixTimesVector
                    try result.append(alloc, (@as(u32, 5) << 16) | 151);
                    try result.append(alloc, ch.result_type);
                    try result.append(alloc, ca.matmul_id);
                    try result.append(alloc, ca.cc_mat_id);
                    try result.append(alloc, ca.cc_vec4_id);
                    is_chain_end = true;
                    break;
                }
            }
            if (is_chain_end) {
                pos = ie;
                continue;
            }
            // Not a chain end, just a removed FAdd
            pos = ie;
            continue;
        }

        // Regular instruction with substitutions
        try result.append(alloc, hdr);
        var i: u32 = 1;
        while (i < wc) : (i += 1) {
            const operand = words[pos + i];
            const replaced = subs.get(operand) orelse operand;
            try result.append(alloc, replaced);
        }

        pos = ie;
    }

    result.items[3] = next_new_id;
    return result.toOwnedSlice(alloc) catch return words;
}
