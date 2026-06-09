// SPDX-License-Identifier: MIT OR Apache-2.0
//! Convert simple loop counter variables (OpVariable + load/store) to OpPhi.
//! Pattern: function-local var with 1 init-store, 1 load in loop header, 1 store in continue block.
//! The load is replaced with OpPhi (opcode 245), stores and variable are removed.

const std = @import("std");
const compact_ids = @import("compact_ids.zig");
const opt = @import("compact_ids_passes.zig");

/// The single unconditional-branch target of `block_label`'s block, or null if
/// its terminator is not a plain OpBranch (conditional/return/etc.) or the block
/// is not found.
fn unconditionalBranchTarget(words: []const u32, block_label: u32) ?u32 {
    var pos: u32 = 5;
    var in_block = false;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const op: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        if (op == 248 and wc >= 2) {
            if (in_block) return null; // next block without a terminator
            in_block = (words[pos + 1] == block_label);
        } else if (in_block) {
            // Terminators: OpBranch(249), OpBranchConditional(250), OpSwitch(251),
            // OpReturn(253), OpReturnValue(254), OpKill(252), OpUnreachable(255).
            if (op == 249 and wc >= 2) return words[pos + 1];
            if (op == 250 or op == 251 or op == 253 or op == 254 or op == 252 or op == 255) return null;
        }
        pos += wc;
    }
    return null;
}

/// Count the blocks whose terminator branches to `target` (CFG predecessors),
/// recording the last such predecessor's label in `last_pred`.
fn predecessorCount(words: []const u32, target: u32, last_pred: *u32) u32 {
    var count: u32 = 0;
    var cur_label: u32 = 0;
    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const op: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        if (op == 248 and wc >= 2) cur_label = words[pos + 1]; // OpLabel
        var hit = false;
        switch (op) {
            249 => if (wc >= 2 and words[pos + 1] == target) { hit = true; }, // OpBranch
            250 => if (wc >= 4 and (words[pos + 2] == target or words[pos + 3] == target)) { hit = true; }, // OpBranchConditional
            251 => { // OpSwitch: selector default [literal target]...
                if (wc >= 3 and words[pos + 2] == target) hit = true;
                var k: u32 = pos + 4;
                while (k < pos + wc) : (k += 2) if (words[k] == target) { hit = true; };
            },
            else => {},
        }
        if (hit) {
            count += 1;
            last_pred.* = cur_label;
        }
        pos += wc;
    }
    return count;
}

/// Whether `block` is a valid "loop update" predecessor of the latch `cont_label`
/// for phi construction: either the store sits directly in the latch (the classic
/// `for`-loop shape), or it sits in a body block that UNCONDITIONALLY branches to
/// the latch where the latch has exactly that ONE predecessor (the classic
/// `while`-loop shape, `… ; i++; }`). The single-predecessor + unconditional-branch
/// requirement guarantees (a) the stored value dominates the latch, so the phi
/// operand `[stored_val, cont_label]` is well-formed, and (b) there is no `break`
/// between the store and the latch, so no loop exit observes a value inconsistent
/// with the phi. Conditional/multi-predecessor updates (e.g. a nested loop's
/// counter against an outer latch, or `if(c) lo=…; else hi=…;`) are conservatively
/// rejected — they fail the unconditional-branch or single-predecessor test.
fn isLoopUpdateBlock(words: []const u32, block: u32, cont_label: u32) bool {
    if (block == cont_label) return true;
    if (unconditionalBranchTarget(words, block) != cont_label) return false;
    var last_pred: u32 = 0;
    return predecessorCount(words, cont_label, &last_pred) == 1 and last_pred == block;
}

/// Whether `pred`'s terminator branches to `target` (i.e. `pred` is a direct CFG
/// predecessor of `target`). Used to confirm the init store's block is a real
/// predecessor of the loop header before using it as the `[init, pred]` phi
/// operand — a cross-loop accumulator (e.g. `sum` initialised outside a nested
/// loop) has its init store far from the inner header and must NOT be converted.
fn isDirectPredecessor(words: []const u32, pred: u32, target: u32) bool {
    var pos: u32 = 5;
    var in_block = false;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const op: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        if (op == 248 and wc >= 2) {
            if (in_block) return false; // left pred's block without finding a match
            in_block = (words[pos + 1] == pred);
        } else if (in_block) {
            switch (op) {
                249 => if (wc >= 2) return words[pos + 1] == target, // OpBranch
                250 => return wc >= 4 and (words[pos + 2] == target or words[pos + 3] == target), // OpBranchConditional
                251 => { // OpSwitch
                    if (wc >= 3 and words[pos + 2] == target) return true;
                    var k: u32 = pos + 4;
                    while (k < pos + wc) : (k += 2) if (words[k] == target) return true;
                    return false;
                },
                252, 253, 254, 255 => return false, // non-branch terminator
                else => {},
            }
        }
        pos += wc;
    }
    return false;
}

pub fn loopCounterToPhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find loop headers via OpLoopMerge (opcode 246)
    var loop_info = std.AutoHashMapUnmanaged(u32, u32).empty; // header_label -> continue_label
    defer loop_info.deinit(alloc);
    var cur_label: u32 = 0;
    var pos: u32 = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 248 and wc >= 2) cur_label = words[pos + 1]; // OpLabel
        if (opcode == 246 and wc >= 4) { // OpLoopMerge
            try loop_info.put(alloc, cur_label, words[pos + 2]); // continue_id
        }
        pos = ie;
    }

    if (loop_info.count() == 0) return words;

    // Phase 2: Collect function-local variables and their load/store patterns
    const StoreInfo = struct { val_id: u32, block: u32 };
    const LoadInfo = struct { result_id: u32, block: u32 };
    const VarInfo = struct {
        var_id: u32,
        pointee_type: u32,
        stores: std.ArrayListUnmanaged(StoreInfo),
        loads: std.ArrayListUnmanaged(LoadInfo),
    };
    var vars = std.ArrayListUnmanaged(VarInfo).empty;
    defer {
        for (vars.items) |*v| {
            v.stores.deinit(alloc);
            v.loads.deinit(alloc);
        }
        vars.deinit(alloc);
    }

    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 59 and wc >= 4) { // OpVariable
            const storage_class = words[pos + 3];
            if (storage_class == 7) { // Function
                const var_id = words[pos + 2];
                const ptr_type_id = words[pos + 1];
                var pointee_type: u32 = 0;
                var tp: u32 = 5;
                while (tp < words.len) {
                    const twc: u32 = words[tp] >> 16;
                    const top: u16 = @truncate(words[tp] & 0xFFFF);
                    if (twc == 0) break;
                    if (top == 32 and twc >= 4 and words[tp + 1] == ptr_type_id) {
                        pointee_type = words[tp + 3];
                        break;
                    }
                    tp += twc;
                }
                try vars.append(alloc, .{
                    .var_id = var_id,
                    .pointee_type = pointee_type,
                    .stores = .empty,
                    .loads = .empty,
                });
            }
        }
        pos = ie;
    }

    if (vars.items.len == 0) return words;

    cur_label = 0;
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        if (opcode == 248 and wc >= 2) cur_label = words[pos + 1];
        if (opcode == 62 and wc >= 3) { // OpStore
            const ptr = words[pos + 1];
            for (vars.items) |*v| {
                if (v.var_id == ptr) {
                    try v.stores.append(alloc, .{ .val_id = words[pos + 2], .block = cur_label });
                }
            }
        }
        if (opcode == 61 and wc >= 4) { // OpLoad
            const ptr = words[pos + 3];
            for (vars.items) |*v| {
                if (v.var_id == ptr) {
                    try v.loads.append(alloc, .{ .result_id = words[pos + 2], .block = cur_label });
                }
            }
        }
        pos = ie;
    }

    // Phase 3: Identify convertible variables
    var sub_map = std.AutoHashMapUnmanaged(u32, u32).empty; // load_result -> phi_result
    defer sub_map.deinit(alloc);
    var remove_store_positions = std.AutoHashMapUnmanaged(u32, void).empty;
    defer remove_store_positions.deinit(alloc);
    var remove_var_ids = std.AutoHashMapUnmanaged(u32, void).empty;
    defer remove_var_ids.deinit(alloc);

    const PhiInsert = struct {
        label_id: u32,
        type_id: u32,
        result_id: u32,
        init_val: u32,
        init_block: u32,
        new_val: u32,
        cont_block: u32,
    };
    var phi_inserts = std.ArrayListUnmanaged(PhiInsert).empty;
    defer phi_inserts.deinit(alloc);

    for (vars.items) |v| {
        if (v.stores.items.len != 2) continue;
        if (v.loads.items.len == 0) continue;
        if (v.pointee_type == 0) continue;

        var lhi = loop_info.iterator();
        while (lhi.next()) |entry| {
            const hdr_label = entry.key_ptr.*;
            const cont_label = entry.value_ptr.*;

            // Classify the two stores: the "cont_store" is the loop-update store
            // (in the latch, or in a body block that dominates the latch — see
            // isLoopUpdateBlock, which also handles `while`-loops whose increment
            // lives in the body rather than the continue block); the other is the
            // pre-header init store.
            var pre_store: ?StoreInfo = null;
            var cont_store: ?StoreInfo = null;
            for (v.stores.items) |s| {
                if (isLoopUpdateBlock(words, s.block, cont_label)) cont_store = s else pre_store = s;
            }
            if (pre_store == null or cont_store == null) continue;

            // The init store's block must be a direct predecessor of the header so
            // the phi operand `[init, pre_block]` is well-formed. A cross-loop
            // accumulator (`sum` initialised before an OUTER loop, updated in an
            // INNER loop) has its init far from the inner header — reject it, or
            // the phi names a non-predecessor block (spirv-val rejects).
            if (!isDirectPredecessor(words, pre_store.?.block, hdr_label)) continue;

            // For the `while`-extension (update store NOT in the latch), require
            // the latch to be a simple unconditional back-edge to the header. A
            // `do { … } while(cond)` loop's latch ends in a CONDITIONAL branch
            // (the bottom test); converting its counter yields a phi whose update
            // lives on that conditional back-edge — which the structured emitters
            // (WGSL/GLSL/MSL/HLSL) do not render, dropping the increment. Keep
            // such loops as memory vars. The classic `for`/`while` latch is an
            // unconditional OpBranch to the header and is unaffected.
            if (cont_store.?.block != cont_label and
                unconditionalBranchTarget(words, cont_label) != hdr_label) continue;

            // Check: all loads are in loop-dominated blocks (not pre-header store block or merge)
            // For structured SPIR-V, any block that is NOT the pre-header or merge is dominated by the header
            const pre_block = pre_store.?.block;

            // First try: load in loop header (existing pattern, reuse load result as phi result)
            var phi_result: ?u32 = null;
            for (v.loads.items) |l| {
                if (l.block == hdr_label) {
                    phi_result = l.result_id;
                    break;
                }
            }

            // Second try: no load in header, but all loads in loop-dominated blocks
            if (phi_result == null) {
                // Check all loads are NOT in pre-header or merge block
                var all_dominated = true;
                for (v.loads.items) |l| {
                    if (l.block == pre_block) {
                        all_dominated = false;
                        break;
                    }
                    // Check if load is in the merge block by looking for OpLabel with merge block label
                    // For simplicity, we check if the load block is the merge target of this loop
                }
                if (!all_dominated) continue;

                // Also check: no load in the loop's merge block
                // Find the merge block by looking for OpLoopMerge in the header block
                var found_merge: u32 = 0;
                var mp2: u32 = 5;
                var in_hdr_block = false;
                while (mp2 < words.len) {
                    const mwc: u32 = words[mp2] >> 16;
                    const mop: u16 = @truncate(words[mp2] & 0xFFFF);
                    if (mwc == 0) break;
                    if (mop == 248) in_hdr_block = (words[mp2 + 1] == hdr_label);
                    if (mop == 246 and in_hdr_block and mwc >= 3) {
                        found_merge = words[mp2 + 1];
                        break;
                    }
                    if (mop == 249 or mop == 250 or mop == 251) in_hdr_block = false; // terminator ends block
                    mp2 += mwc;
                }
                if (found_merge > 0) {
                    for (v.loads.items) |l| {
                        if (l.block == found_merge) {
                            all_dominated = false;
                            break;
                        }
                    }
                }
                if (!all_dominated) continue;

                // All loads are in dominated blocks. Use first load's result as phi result.
                // But we need a fresh ID for the phi result since no load is in the header.
                // Actually, we can still reuse any load result — just use the first one.
                phi_result = v.loads.items[0].result_id;
                // reuse is fine, we'll just substitute all loads
            }

            if (phi_result == null) continue;

            try phi_inserts.append(alloc, .{
                .label_id = hdr_label,
                .type_id = v.pointee_type,
                .result_id = phi_result.?,
                .init_val = pre_store.?.val_id,
                .init_block = pre_store.?.block,
                .new_val = cont_store.?.val_id,
                .cont_block = cont_label,
            });

            for (v.loads.items) |l| {
                try sub_map.put(alloc, l.result_id, phi_result.?);
            }

            // Find store positions to remove
            cur_label = 0;
            pos = 5;
            while (pos < words.len) {
                const wc2: u32 = words[pos] >> 16;
                const op2: u16 = @truncate(words[pos] & 0xFFFF);
                if (wc2 == 0) break;
                const ie2 = pos + wc2;
                if (ie2 > words.len) break;
                if (op2 == 248 and wc2 >= 2) cur_label = words[pos + 1];
                if (op2 == 62 and wc2 >= 3 and words[pos + 1] == v.var_id) {
                    // Remove BOTH the init store (pre-header) and the loop-update
                    // store. The latter may live in the latch (`for`) or in a body
                    // block that dominates the latch (`while`); key off the store's
                    // actual block, not cont_label.
                    if (cur_label == cont_store.?.block or cur_label == pre_store.?.block) {
                        try remove_store_positions.put(alloc, pos, {});
                    }
                }
                pos = ie2;
            }

            try remove_var_ids.put(alloc, v.var_id, {});
            break;
        }
    }

    if (phi_inserts.items.len == 0) return words;

    // Phase 4: Group phi inserts by label
    var phis_by_label = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(PhiInsert)){};
    defer {
        var it = phis_by_label.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(alloc);
        phis_by_label.deinit(alloc);
    }
    for (phi_inserts.items) |phi| {
        const gop = try phis_by_label.getOrPut(alloc, phi.label_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, phi);
    }

    // Phase 5: Build output
    var result = std.ArrayList(u32).initCapacity(alloc, words.len + phi_inserts.items.len * 7) catch return words;
    result.appendSliceAssumeCapacity(words[0..5]);

    cur_label = 0;
    pos = 5;
    while (pos < words.len) {
        const wc: u32 = words[pos] >> 16;
        const opcode: u16 = @truncate(words[pos] & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip removed stores
        if (opcode == 62 and remove_store_positions.contains(pos)) {
            pos = ie;
            continue;
        }
        // Skip removed variable definitions
        if (opcode == 59 and wc >= 4 and remove_var_ids.contains(words[pos + 2])) {
            pos = ie;
            continue;
        }
        // Skip removed loads
        if (opcode == 61 and wc >= 4 and sub_map.contains(words[pos + 2])) {
            pos = ie;
            continue;
        }

        // Handle OpLabel: copy + insert OpPhi after
        if (opcode == 248 and wc >= 2) {
            cur_label = words[pos + 1];
            try result.appendSlice(alloc, words[pos .. ie]);

            if (phis_by_label.get(cur_label)) |phis| {
                for (phis.items) |phi| {
                    // OpPhi: wc=7, opcode=245
                    try result.append(alloc, (7 << 16) | 245);
                    try result.append(alloc, phi.type_id);
                    try result.append(alloc, phi.result_id);
                    try result.append(alloc, phi.init_val);
                    try result.append(alloc, phi.init_block);
                    try result.append(alloc, phi.new_val);
                    try result.append(alloc, phi.cont_block);
                }
            }
            pos = ie;
            continue;
        }

        // Apply sub_map to all other instructions
        const info = compact_ids.getOpInfo(opcode) orelse {
            try result.append(alloc, words[pos]);
            var wi: u32 = pos + 1;
            while (wi < ie) : (wi += 1) {
                try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]);
            }
            pos = ie;
            continue;
        };

        try result.append(alloc, words[pos]);
        var wi: u32 = pos + 1;
        switch (info.fixed) {
            0 => {},
            1 => { if (wi < ie) { try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); wi += 1; } },
            2 => {
                if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                if (wi < ie) { try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); wi += 1; }
            },
            3 => { if (wi < ie) { try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); wi += 1; } },
            else => {},
        }
        for (info.ops) |ch| {
            if (wi >= ie) break;
            switch (ch) {
                'i' => { try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); wi += 1; },
                'l' => { try result.append(alloc, words[wi]); wi += 1; },
                'I' => { while (wi < ie) : (wi += 1) try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); },
                'L', 's' => { while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]); },
                'M' => {
                    if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                    while (wi < ie) : (wi += 1) try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]);
                },
                'W' => {
                    while (wi + 1 < ie) {
                        try result.append(alloc, words[wi]); // literal
                        wi += 1;
                        try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]); // target
                        wi += 1;
                    }
                    if (wi < ie) { try result.append(alloc, words[wi]); wi += 1; }
                },
                'E' => {
                    var in_str = true;
                    while (wi < ie and in_str) : (wi += 1) {
                        const w = words[wi]; try result.append(alloc, w);
                        if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                    }
                    while (wi < ie) : (wi += 1) try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]);
                },
                else => { try result.append(alloc, words[wi]); wi += 1; },
            }
        }
        while (wi < ie) : (wi += 1) try result.append(alloc, words[wi]);
        pos = ie;
    }

    const nw = result.toOwnedSlice(alloc) catch return words;
    const dce = opt.deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}
