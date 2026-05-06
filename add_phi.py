#!/usr/bin/env python3
"""Add branchMergePhi function to compact_ids.zig"""
import os

base = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(base, 'src', 'compact_ids.zig')

with open(src, 'r', encoding='utf-8') as f:
    content = f.read()

func = '''
pub fn branchMergePhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    const Pair = struct { pred: u32, value: u32 };
    const BlockInfo = struct {
        preds: std.ArrayListUnmanaged(u32),
        succs: std.ArrayListUnmanaged(u32),
        stores: std.AutoHashMapUnmanaged(u32, u32),
        loads: std.AutoHashMapUnmanaged(u32, u32),
    };
    var block_map = std.AutoHashMapUnmanaged(u32, BlockInfo){};
    defer {
        var it = block_map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.preds.deinit(alloc);
            entry.value_ptr.succs.deinit(alloc);
            entry.value_ptr.stores.deinit(alloc);
            entry.value_ptr.loads.deinit(alloc);
        }
        block_map.deinit(alloc);
    }

    var current_block: u32 = 0;
    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 248) {
            current_block = words[pos + 1];
            const gop = try block_map.getOrPut(alloc, current_block);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .preds = .{}, .succs = .{}, .stores = .{}, .loads = .{} };
            }
        }
        if (block_map.getPtr(current_block)) |block| {
            if (opcode == 62 and wc >= 3) try block.stores.put(alloc, words[pos + 1], words[pos + 2]);
            if (opcode == 61 and wc >= 4) try block.loads.put(alloc, words[pos + 3], words[pos + 2]);
            if (opcode == 249 and wc >= 2) try block.succs.append(alloc, words[pos + 1]);
            if (opcode == 250 and wc >= 4) {
                try block.succs.append(alloc, words[pos + 2]);
                try block.succs.append(alloc, words[pos + 3]);
            }
            if (opcode == 251 and wc >= 3) {
                var i: u32 = 2;
                while (i < wc) : (i += 1) try block.succs.append(alloc, words[pos + i]);
            }
        }
        pos = ie;
    }
    {
        var it = block_map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.succs.items) |succ| {
                if (block_map.getPtr(succ)) |sb| try sb.preds.append(alloc, entry.key_ptr.*);
            }
        }
    }
    var cands = std.ArrayListUnmanaged(struct { merge_block: u32, var_id: u32, load_result: u32, result_type: u32, pred_values: []Pair }){};
    defer {
        for (cands.items) |c| alloc.free(c.pred_values);
        cands.deinit(alloc);
    }
    {
        var bit = block_map.iterator();
        while (bit.next()) |entry| {
            const bid = entry.key_ptr.*;
            const block = entry.value_ptr.*;
            if (block.preds.items.len < 2) continue;
            var lit = block.loads.iterator();
            while (lit.next()) |le| {
                const var_id = le.key_ptr.*;
                const load_result = le.value_ptr.*;
                var pv = std.ArrayListUnmanaged(Pair){};
                errdefer pv.deinit(alloc);
                var ok = true;
                for (block.preds.items) |pred| {
                    if (block_map.get(pred)) |pb| {
                        if (pb.stores.get(var_id)) |val| {
                            try pv.append(alloc, .{ .pred = pred, .value = val });
                        } else { ok = false; break; }
                    } else { ok = false; break; }
                }
                if (!ok or pv.items.len < 2) { pv.deinit(alloc); continue; }
                var bad = false;
                var cit = block_map.iterator();
                while (cit.next()) |ce| {
                    if (ce.key_ptr.* != bid and ce.value_ptr.loads.contains(var_id)) { bad = true; break; }
                    var is_pred = false;
                    for (pv.items) |p| { if (ce.key_ptr.* == p.pred) { is_pred = true; break; } }
                    if (!is_pred and ce.value_ptr.stores.contains(var_id)) { bad = true; break; }
                }
                if (bad) { pv.deinit(alloc); continue; }
                var rtype: u32 = 0;
                var p2: u32 = 5;
                while (p2 < words.len) {
                    const h2 = words[p2]; const w2: u32 = h2 >> 16; const o2: u16 = @truncate(h2 & 0xFFFF);
                    if (w2 == 0) break;
                    const e2 = p2 + w2;
                    if (e2 > words.len) break;
                    if (o2 == 61 and w2 >= 4 and words[p2 + 2] == load_result) { rtype = words[p2 + 1]; break; }
                    p2 = e2;
                }
                if (rtype == 0) { pv.deinit(alloc); continue; }
                try cands.append(alloc, .{ .merge_block = bid, .var_id = var_id, .load_result = load_result, .result_type = rtype, .pred_values = try pv.toOwnedSlice(alloc) });
            }
        }
    }
    if (cands.items.len == 0) return words;
    var load_map = std.AutoHashMapUnmanaged(u32, u32){};
    defer load_map.deinit(alloc);
    var remove_vars = std.AutoHashMapUnmanaged(u32, void){};
    defer remove_vars.deinit(alloc);
    var remove_stores = std.AutoHashMapUnmanaged(u64, void){};
    defer remove_stores.deinit(alloc);
    var merge_phis = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(struct { result_type: u32, phi_id: u32, pairs: []Pair })){};
    defer {
        var mi = merge_phis.iterator();
        while (mi.next()) |e| e.value_ptr.deinit(alloc);
        merge_phis.deinit(alloc);
    }
    var next_id: u32 = bound;
    for (cands.items) |c| {
        const phi_id = next_id;
        next_id += 1;
        try load_map.put(alloc, c.load_result, phi_id);
        try remove_vars.put(alloc, c.var_id, {});
        for (c.pred_values) |pv| {
            try remove_stores.put(alloc, (@as(u64, pv.pred) << 32) | @as(u64, c.var_id), {});
        }
        const gop = try merge_phis.getOrPut(alloc, c.merge_block);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(alloc, .{ .result_type = c.result_type, .phi_id = phi_id, .pairs = c.pred_values });
    }
    var result = std.ArrayList(u32).initCapacity(alloc, words.len) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);
    result.items[3] = next_id;
    current_block = 0;
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos]; const wc: u32 = hdr >> 16; const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 248) {
            current_block = words[pos + 1];
            try result.appendSlice(alloc, words[pos..ie]);
            if (merge_phis.get(current_block)) |phis| {
                for (phis.items) |phi| {
                    const phi_wc: u32 = 2 + 2 * @as(u32, @intCast(phi.pairs.len));
                    try result.append(alloc, (phi_wc << 16) | 126);
                    try result.append(alloc, phi.result_type);
                    try result.append(alloc, phi.phi_id);
                    for (phi.pairs) |pair| {
                        try result.append(alloc, pair.value);
                        try result.append(alloc, pair.pred);
                    }
                }
            }
            pos = ie;
            continue;
        }
        if (opcode == 59 and wc >= 4 and remove_vars.contains(words[pos + 1])) { pos = ie; continue; }
        if (opcode == 61 and wc >= 4 and load_map.contains(words[pos + 2])) { pos = ie; continue; }
        if (opcode == 62 and wc >= 3) {
            const key = (@as(u64, current_block) << 32) | @as(u64, words[pos + 1]);
            if (remove_stores.contains(key)) { pos = ie; continue; }
        }
        const info = getOpInfo(opcode) orelse {
            try result.appendSlice(alloc, words[pos..ie]);
            pos = ie; continue;
        };
        var wi: u32 = pos + 1;
        try result.append(alloc, hdr);
        switch (info.fixed) {
            1 => { if (wi < ie) { try result.append(alloc, load_map.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, load_map.get(words[wi]) orelse words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, load_map.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, load_map.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }
    return result.toOwnedSlice(alloc) catch return words;
}
'''

if 'branchMergePhi' in content:
    print("branchMergePhi already exists, skipping")
else:
    content = content + func
    with open(src, 'w', encoding='utf-8') as f:
        f.write(content)
    print("OK: appended branchMergePhi")
