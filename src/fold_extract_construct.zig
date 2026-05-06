/// foldExtractConstructToShuffle: Replace patterns like:
///   %a = OpCompositeExtract %float %src 0
///   %b = OpCompositeExtract %float %src 1
///   %c = OpCompositeConstruct %v3float %a %float_0 %b
/// with:
///   %c = OpVectorShuffle %v3float %src %zero_vec 0 (src_len+0) 1
/// Saves N IDs where N = number of extract instructions eliminated.
const std = @import("std");

pub fn foldExtractConstructToShuffle(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    const bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Build maps
    var extract_sources = std.AutoHashMapUnmanaged(u32, u32){}; // extract result -> source
    defer extract_sources.deinit(alloc);
    var extract_indices = std.AutoHashMapUnmanaged(u32, u32){}; // extract result -> index
    defer extract_indices.deinit(alloc);

    var float_const_vals = std.AutoHashMapUnmanaged(u32, u32){}; // const result -> value_bits
    defer float_const_vals.deinit(alloc);

    var cc_constituents = std.AutoHashMapUnmanaged(u32, []const u32){};
    defer {
        var it = cc_constituents.iterator();
        while (it.next()) |entry| alloc.free(entry.value_ptr.*);
        cc_constituents.deinit(alloc);
    }

    // Zero vector constants: result_id -> num_components
    var zero_vecs = std.AutoHashMapUnmanaged(u32, u32){}; // result -> num_comps
    defer zero_vecs.deinit(alloc);

    var pos: u32 = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        if (opcode == 81 and wc == 5) { // OpCompositeExtract with single index
            const result_id = words[pos + 2];
            const source = words[pos + 3];
            const index = words[pos + 4];
            try extract_sources.put(alloc, result_id, source);
            try extract_indices.put(alloc, result_id, index);
        } else if (opcode == 43 and wc >= 4) { // OpConstant
            const result_id = words[pos + 2];
            const val = words[pos + 3];
            try float_const_vals.put(alloc, result_id, val);
        } else if (opcode == 80 and wc >= 4) { // OpCompositeConstruct
            const result_id = words[pos + 2];
            const constituents = try alloc.dupe(u32, words[pos + 3 .. ie]);
            try cc_constituents.put(alloc, result_id, constituents);
        } else if (opcode == 44 and wc >= 4) { // OpConstantComposite
            const result_id = words[pos + 2];
            const constituents = words[pos + 3 .. ie];
            var all_zero = true;
            for (constituents) |cid| {
                const v = float_const_vals.get(cid) orelse {
                    all_zero = false;
                    break;
                };
                if (v != 0) { // not float 0.0
                    all_zero = false;
                    break;
                }
            }
            if (all_zero and constituents.len >= 2) {
                try zero_vecs.put(alloc, result_id, @intCast(constituents.len));
            }
        }
        pos = ie;
    }

    if (cc_constituents.count() == 0 or extract_sources.count() == 0) return words;
    if (zero_vecs.count() == 0) return words;

    // Phase 2: Use counts for extract results (skip result_id position at offset 2)
    var use_counts = std.AutoHashMapUnmanaged(u32, u32){};
    defer use_counts.deinit(alloc);
    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;
        var i: u32 = 1;
        while (i < wc) : (i += 1) {
            if (i == 2) continue; // skip result_id
            const uid = words[pos + i];
            if (uid > 0 and uid < bound) {
                const gop = try use_counts.getOrPut(alloc, uid);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }
        pos = ie;
    }

    // Phase 3: Find replacements
    const Replacement = struct { source: u32, zero_vec: u32, indices: []const u32, source_len: u32 };
    var replacements = std.AutoHashMapUnmanaged(u32, Replacement){};
    defer {
        var rit = replacements.iterator();
        while (rit.next()) |entry| alloc.free(entry.value_ptr.indices);
        replacements.deinit(alloc);
    }

    var extracts_to_remove = std.AutoHashMapUnmanaged(u32, void){};
    defer extracts_to_remove.deinit(alloc);

    var cc_it = cc_constituents.iterator();
    while (cc_it.next()) |entry| {
        const cc_id = entry.key_ptr.*;
        const constituents = entry.value_ptr.*;

        if (constituents.len < 2) continue;

        var common_source: u32 = 0;
        var has_extract = false;
        var all_ok = true;
        var num_extracts: u32 = 0;
        var max_extract_idx: u32 = 0;

        for (constituents) |cid| {
            if (extract_sources.get(cid)) |src| {
                if (common_source == 0) {
                    common_source = src;
                } else if (src != common_source) {
                    all_ok = false;
                    break;
                }
                has_extract = true;
                num_extracts += 1;
                const idx = extract_indices.get(cid) orelse 0;
                if (idx > max_extract_idx) max_extract_idx = idx;
            } else if (float_const_vals.get(cid)) |val| {
                if (val != 0) { // only fold 0.0 constants
                    all_ok = false;
                    break;
                }
            } else {
                all_ok = false;
                break;
            }
        }

        if (!all_ok or !has_extract or common_source == 0) continue;

        // Check all extract results are single-use
        var all_single_use = true;
        for (constituents) |cid| {
            if (extract_sources.contains(cid)) {
                const uses = use_counts.get(cid) orelse 0;
                if (uses != 1) {
                    all_single_use = false;
                    break;
                }
            }
        }
        if (!all_single_use) continue;

        const source_len = max_extract_idx + 1;

        // Find a suitable zero vector
        var chosen_zero_vec: u32 = 0;
        var zit = zero_vecs.iterator();
        while (zit.next()) |ze| {
            if (ze.value_ptr.* >= 1) {
                chosen_zero_vec = ze.key_ptr.*;
                break;
            }
        }
        if (chosen_zero_vec == 0) continue;

        // Build shuffle indices
        const shuffle_indices = try alloc.alloc(u32, constituents.len);
        for (constituents, 0..) |cid, i| {
            if (extract_indices.get(cid)) |idx| {
                shuffle_indices[i] = idx;
            } else {
                // 0.0 constant -> first component of zero vector
                shuffle_indices[i] = source_len;
            }
        }

        try replacements.put(alloc, cc_id, .{ .source = common_source, .zero_vec = chosen_zero_vec, .indices = shuffle_indices, .source_len = source_len });

        for (constituents) |cid| {
            if (extract_sources.contains(cid)) {
                try extracts_to_remove.put(alloc, cid, {});
            }
        }
    }

    if (replacements.count() == 0) return words;

    // Phase 4: Rewrite
    var result = try std.ArrayList(u32).initCapacity(alloc, words.len);
    errdefer result.deinit(alloc);
    result.appendSliceAssumeCapacity(words[0..5]);

    pos = 5;
    while (pos < words.len) {
        const hdr = words[pos];
        const wc: u32 = hdr >> 16;
        const opcode: u16 = @truncate(hdr & 0xFFFF);
        if (wc == 0) break;
        const ie = pos + wc;
        if (ie > words.len) break;

        // Skip extract instructions being removed
        if (opcode == 81 and wc >= 5) {
            const result_id = words[pos + 2];
            if (extracts_to_remove.contains(result_id)) {
                pos = ie;
                continue;
            }
        }

        // Replace CompositeConstruct with VectorShuffle
        if (opcode == 80 and wc >= 4) {
            const result_id = words[pos + 2];
            if (replacements.get(result_id)) |rep| {
                const result_type = words[pos + 1];
                const n_indices: u16 = @intCast(rep.indices.len);
                const shuffle_wc: u16 = 5 + n_indices;
                // OpVectorShuffle = opcode 79
                try result.append(alloc, (@as(u32, shuffle_wc) << 16) | 79);
                try result.append(alloc, result_type);
                try result.append(alloc, result_id);
                try result.append(alloc, rep.source);
                try result.append(alloc, rep.zero_vec);
                for (rep.indices) |idx| {
                    try result.append(alloc, idx);
                }
                pos = ie;
                continue;
            }
        }

        try result.appendSlice(alloc, words[pos..ie]);
        pos = ie;
    }

    return result.toOwnedSlice(alloc) catch return words;
}
