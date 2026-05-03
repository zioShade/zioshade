//! Convert simple loop counter variables (OpVariable + load/store) to OpPhi.
//! Pattern: function-local var with 1 init-store, 1 load in loop header, 1 store in continue block.
//! The load is replaced with OpPhi (opcode 245), stores and variable are removed.

const std = @import("std");
const compact_ids = @import("compact_ids.zig");

pub fn loopCounterToPhi(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find loop headers via OpLoopMerge (opcode 246)
    var loop_info = std.AutoHashMapUnmanaged(u32, u32){}; // header_label -> continue_label
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
    var vars = std.ArrayListUnmanaged(VarInfo){};
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
                    .stores = .{},
                    .loads = .{},
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
    var sub_map = std.AutoHashMapUnmanaged(u32, u32){}; // load_result -> phi_result
    defer sub_map.deinit(alloc);
    var remove_store_positions = std.AutoHashMapUnmanaged(u32, void){};
    defer remove_store_positions.deinit(alloc);
    var remove_var_ids = std.AutoHashMapUnmanaged(u32, void){};
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
    var phi_inserts = std.ArrayListUnmanaged(PhiInsert){};
    defer phi_inserts.deinit(alloc);

    for (vars.items) |v| {
        if (v.stores.items.len != 2) continue;
        if (v.loads.items.len == 0) continue;
        if (v.pointee_type == 0) continue;

        var lhi = loop_info.iterator();
        while (lhi.next()) |entry| {
            const hdr_label = entry.key_ptr.*;
            const cont_label = entry.value_ptr.*;

            var pre_store: ?StoreInfo = null;
            var cont_store: ?StoreInfo = null;
            for (v.stores.items) |s| {
                if (s.block == cont_label) cont_store = s else pre_store = s;
            }
            if (pre_store == null or cont_store == null) continue;

            var header_result: ?u32 = null;
            for (v.loads.items) |l| {
                if (l.block == hdr_label) {
                    header_result = l.result_id;
                    break;
                }
            }
            if (header_result == null) continue;

            const phi_result = header_result.?;
            try phi_inserts.append(alloc, .{
                .label_id = hdr_label,
                .type_id = v.pointee_type,
                .result_id = phi_result,
                .init_val = pre_store.?.val_id,
                .init_block = pre_store.?.block,
                .new_val = cont_store.?.val_id,
                .cont_block = cont_label,
            });

            for (v.loads.items) |l| {
                try sub_map.put(alloc, l.result_id, phi_result);
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
                    if (cur_label == cont_label or cur_label == pre_store.?.block) {
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
        if (!gop.found_existing) gop.value_ptr.* = .{};
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
                        wi += 1; try result.append(alloc, words[wi]);
                        wi += 1; try result.append(alloc, sub_map.get(words[wi]) orelse words[wi]);
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
    const dce = compact_ids.deadCodeElim(alloc, nw) catch return nw;
    if (dce.ptr != nw.ptr) alloc.free(nw);
    return dce;
}
