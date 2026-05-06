const std = @import("std");
const compact_ids = @import("compact_ids.zig");

pub fn inlineMultiBlock(alloc: std.mem.Allocator, words: []const u32) error{OutOfMemory}![]const u32 {
    var bound = words[3];
    if (bound <= 1) return words;

    // Phase 1: Find all functions
    const FI = struct {
        id: u32,
        start: u32,
        end: u32,
        body_after_entry: u32,
        body_end: u32,
        params: []const u32,
        ret_id: u32,
        n_ret: u32,
        n_blk: u32,
        has_fvars: bool,
    };
    var funcs = std.ArrayListUnmanaged(FI){};
    defer {
        for (funcs.items) |f| alloc.free(f.params);
        funcs.deinit(alloc);
    }

    var p: u32 = 5;
    while (p < words.len) {
        const h = words[p]; const wc: u32 = h >> 16; const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        const ie = p + wc;
        if (ie > words.len) break;
        if (op == 54 and wc >= 5) {
            const fid = words[p + 2];
            var fend: u32 = ie;
            var lbl_pos: u32 = 0;
            var params = std.ArrayListUnmanaged(u32){};
            var ret_id: u32 = 0;
            var n_ret: u32 = 0;
            var n_blk: u32 = 0;
            var has_fvars = false;
            var in_entry = true;
            var fp: u32 = ie;
            while (fp < words.len) {
                const fh = words[fp]; const fwc: u32 = fh >> 16; const fop: u16 = @truncate(fh & 0xFFFF);
                if (fwc == 0) break;
                const fie = fp + fwc;
                if (fie > words.len) break;
                if (fop == 56) { fend = fie; break; }
                if (fop == 55 and fwc >= 3) try params.append(alloc, words[fp + 2]);
                if (fop == 248) { n_blk += 1; if (lbl_pos == 0) lbl_pos = fp; in_entry = (n_blk == 1); }
                if (fop == 59 and in_entry and fwc >= 4 and words[fp + 3] == 7) has_fvars = true;
                if (fop == 249 or fop == 250 or fop == 251) in_entry = false;
                if (fop == 254 and fwc >= 2) { n_ret += 1; ret_id = words[fp + 1]; }
                fp = fie;
            }
            const ba: u32 = if (lbl_pos > 0) lbl_pos + (words[lbl_pos] >> 16) else fend;
            const ps = try params.toOwnedSlice(alloc);
            try funcs.append(alloc, .{ .id = fid, .start = p, .end = fend, .body_after_entry = ba, .body_end = fend -| 1, .params = ps, .ret_id = ret_id, .n_ret = n_ret, .n_blk = n_blk, .has_fvars = has_fvars });
            p = fend;
            continue;
        }
        p = ie;
    }

    // Phase 2: Find entry points, call counts
    var eps = std.AutoHashMapUnmanaged(u32, void){};
    defer eps.deinit(alloc);
    p = 5;
    while (p < words.len) {
        const h = words[p]; const wc: u32 = h >> 16; const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        if (op == 15 and wc >= 3) try eps.put(alloc, words[p + 2], {});
        p += wc;
    }

    var ccounts = std.AutoHashMapUnmanaged(u32, u32){};
    defer ccounts.deinit(alloc);
    var csites = std.AutoHashMapUnmanaged(u32, u32){};
    defer csites.deinit(alloc);
    p = 5;
    while (p < words.len) {
        const h = words[p]; const wc: u32 = h >> 16; const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        if (op == 57 and wc >= 4) {
            const callee = words[p + 3];
            const g = try ccounts.getOrPut(alloc, callee);
            if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
            try csites.put(alloc, callee, p);
        }
        p += wc;
    }

    // Phase 3: Find target (called once, not EP, single return, multi-block, no func vars)
    var tgt: ?*const FI = null;
    for (funcs.items) |*fi| {
        if ((ccounts.get(fi.id) orelse 0) == 1 and
            !eps.contains(fi.id) and
            (fi.n_ret == 1 or fi.n_ret == 0) and
            fi.n_blk >= 2 and fi.n_blk <= 8 and
            fi.body_after_entry < fi.body_end and
            !fi.has_fvars)
        {
            tgt = fi;
            break;
        }
    }
    if (tgt == null) return words;
    const fi = tgt.?;
    const cpos = csites.get(fi.id) orelse return words;

    // Safety check: verify no ID defined in the callee body is referenced
    // by other functions (outside the callee). If so, we can't safely inline.
    var callee_defs = std.AutoHashMapUnmanaged(u32, void){};
    defer callee_defs.deinit(alloc);
    var bp2: u32 = fi.body_after_entry;
    while (bp2 < fi.body_end) {
        const bh = words[bp2]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
        if (bwc == 0) break;
        const bie = bp2 + bwc;
        const info = compact_ids.getOpInfo(bop) orelse { bp2 = bie; continue; };
        if (info.fixed == 2 and bwc >= 3) try callee_defs.put(alloc, words[bp2 + 2], {});
        if (info.fixed == 3 and bwc >= 2) try callee_defs.put(alloc, words[bp2 + 1], {});
        bp2 = bie;
    }
    // Also include the function ID and parameter IDs
    try callee_defs.put(alloc, fi.id, {});
    for (fi.params) |pid| try callee_defs.put(alloc, pid, {});

    // Check if any callee-defined ID is used outside the callee
    var pos3: u32 = 5;
    var in_callee_check = false;
    while (pos3 < words.len) {
        const hdr2 = words[pos3]; const wc2: u32 = hdr2 >> 16; const op2: u16 = @truncate(hdr2 & 0xFFFF);
        if (wc2 == 0) break;
        const ie2 = pos3 + wc2;
        if (ie2 > words.len) break;
        if (op2 == 54 and wc2 >= 5 and words[pos3 + 2] == fi.id) { in_callee_check = true; pos3 = ie2; continue; }
        if (in_callee_check and op2 == 56) { in_callee_check = false; pos3 = ie2; continue; }
        if (in_callee_check) { pos3 = ie2; continue; }
        // Skip OpName/OpMemberName (debug info) — safe to remove later
        if (op2 == 5 or op2 == 6) { pos3 = ie2; continue; }
        // Skip the call site itself — it references callee's function ID which is expected
        if (pos3 == cpos) { pos3 = ie2; continue; }
        // Check operands of non-callee instructions
        for (0..wc2) |i| {
            if (i == 0) continue; // skip header
            const word = words[pos3 + i];
            if (callee_defs.contains(word)) {
                // Found a callee-defined ID used outside the callee - unsafe to inline
                return words;
            }
        }
        pos3 = ie2;
    }

    // Phase 4: Build ID remap
    var idmap = std.AutoHashMapUnmanaged(u32, u32){};
    defer idmap.deinit(alloc);

    const cwc: u32 = words[cpos] >> 16;
    const crid = words[cpos + 2]; // call result ID

    var bp: u32 = fi.body_after_entry;
    while (bp < fi.body_end) {
        const bh = words[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
        if (bwc == 0) break;
        const bie = bp + bwc;
        const info = compact_ids.getOpInfo(bop) orelse { bp = bie; continue; };
        if (info.fixed == 2 and bwc >= 3) {
            const rid = words[bp + 2];
            if (rid != fi.ret_id) {
                bound += 1;
                try idmap.put(alloc, rid, bound - 1);
            }
        } else if (info.fixed == 3 and bwc >= 2) {
            const rid = words[bp + 1];
            if (rid != fi.ret_id) {
                bound += 1;
                try idmap.put(alloc, rid, bound - 1);
            }
        }
        bp = bie;
    }
    // Map params to call args
    for (fi.params, 0..) |pid, i| {
        const off: u32 = @as(u32, @intCast(i)) + 4;
        if (off < cwc) try idmap.put(alloc, pid, words[cpos + off]);
    }
    // Map callee's entry label to caller's current block label
    {
        var caller_lbl: u32 = 0;
        var scan: u32 = 5;
        while (scan < words.len) {
            const sh = words[scan]; const swc: u32 = sh >> 16; const sop: u16 = @truncate(sh & 0xFFFF);
            if (swc == 0) break;
            const sie = scan + swc;
            if (sie > words.len) break;
            if (sop == 248 and swc >= 2) caller_lbl = words[scan + 1];
            if (scan == cpos) break;
            scan = sie;
        }
        var fp3: u32 = fi.start;
        while (fp3 < fi.body_after_entry) {
            const fh3 = words[fp3]; const fwc3: u32 = fh3 >> 16; const fop3: u16 = @truncate(fh3 & 0xFFFF);
            if (fwc3 == 0) break;
            const fie3 = fp3 + fwc3;
            if (fop3 == 248 and fwc3 >= 2) {
                try idmap.put(alloc, words[fp3 + 1], caller_lbl);
                break;
            }
            fp3 = fie3;
        }
    }
    // Continuation label
    bound += 1;
    const cont_lbl = bound - 1;

    // Phase 5: Emit output
    var out = std.ArrayList(u32).initCapacity(alloc, words.len + 64) catch return words;
    out.appendSliceAssumeCapacity(words[0..5]);

    p = 5;
    var in_callee = false;
    while (p < words.len) {
        const h = words[p]; const wc: u32 = h >> 16; const op: u16 = @truncate(h & 0xFFFF);
        if (wc == 0) break;
        const ie = p + wc;
        if (ie > words.len) break;

        // Skip callee function definition
        if (op == 54 and wc >= 5 and words[p + 2] == fi.id) { in_callee = true; p = ie; continue; }
        if (in_callee and op == 56) { in_callee = false; p = ie; continue; }
        if (in_callee) { p = ie; continue; }

        // At call site: emit inlined body
        if (p == cpos) {
            bp = fi.body_after_entry;
            while (bp < fi.body_end) {
                const bh = words[bp]; const bwc: u32 = bh >> 16; const bop: u16 = @truncate(bh & 0xFFFF);
                if (bwc == 0) break;
                const bie = bp + bwc;

                if (bop == 254) { // OpReturnValue -> OpBranch to cont
                    try out.append(alloc, (2 << 16) | 249);
                    try out.append(alloc, cont_lbl);
                    bp = bie;
                    continue;
                }
                if (bop == 253) { // OpReturn -> OpBranch to cont (void case)
                    try out.append(alloc, (2 << 16) | 249);
                    try out.append(alloc, cont_lbl);
                    bp = bie;
                    continue;
                }

                try emitRemap(alloc, &out, words, bp, bie, fi.ret_id, crid, &idmap);
                bp = bie;
            }
            // Continuation label
            try out.append(alloc, (2 << 16) | 248);
            try out.append(alloc, cont_lbl);
            // Emit caller's remaining instructions in this block
            p = cpos + cwc;
            while (p < words.len) {
                const h2 = words[p]; const wc2: u32 = h2 >> 16; const op2: u16 = @truncate(h2 & 0xFFFF);
                if (wc2 == 0) break;
                const ie2 = p + wc2;
                if (ie2 > words.len) break;
                if (op2 == 248 or op2 == 56) break;
                try out.appendSlice(alloc, words[p..ie2]);
                p = ie2;
            }
            continue;
        }

        // Skip OpName/OpMemberName for callee and its internal IDs
        if ((op == 5 or op == 6) and wc >= 3 and callee_defs.contains(words[p + 1])) { p = ie; continue; }

        try out.appendSlice(alloc, words[p..ie]);
        p = ie;
    }

    out.items[3] = bound;
    return out.toOwnedSlice(alloc) catch return words;
}

fn emitRemap(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u32),
    words: []const u32,
    start: u32,
    end: u32,
    ret_id: u32,
    call_rid: u32,
    idmap: *const std.AutoHashMapUnmanaged(u32, u32),
) !void {
    const bh = words[start]; const bop: u16 = @truncate(bh & 0xFFFF);
    const info = compact_ids.getOpInfo(bop) orelse {
        try out.append(alloc, bh);
        var wi: u32 = start + 1;
        while (wi < end) : (wi += 1) {
            const w = words[wi];
            try out.append(alloc, if (w > 0 and w < words[3]) (idmap.get(w) orelse w) else w);
        }
        return;
    };

    try out.append(alloc, bh);
    var wi: u32 = start + 1;

    switch (info.fixed) {
        0 => {},
        1 => { if (wi < end) { try out.append(alloc, words[wi]); wi += 1; } },
        2 => {
            if (wi < end) { try out.append(alloc, words[wi]); wi += 1; }
            if (wi < end) {
                const rid = words[wi];
                try out.append(alloc, if (rid == ret_id) call_rid else (idmap.get(rid) orelse rid));
                wi += 1;
            }
        },
        3 => {
            if (wi < end) {
                const rid = words[wi];
                try out.append(alloc, if (rid == ret_id) call_rid else (idmap.get(rid) orelse rid));
                wi += 1;
            }
        },
        else => {},
    }

    for (info.ops) |ch| {
        if (wi >= end) break;
        switch (ch) {
            'i' => { const w = words[wi]; try out.append(alloc, idmap.get(w) orelse w); wi += 1; },
            'l' => { try out.append(alloc, words[wi]); wi += 1; },
            'I' => { while (wi < end) : (wi += 1) { const w = words[wi]; try out.append(alloc, idmap.get(w) orelse w); } },
            'L', 's' => { while (wi < end) : (wi += 1) try out.append(alloc, words[wi]); },
            'M' => {
                if (wi < end) { try out.append(alloc, words[wi]); wi += 1; }
                while (wi < end) : (wi += 1) { const w = words[wi]; try out.append(alloc, idmap.get(w) orelse w); }
            },
            'W' => {
                while (wi + 1 < end) {
                    wi += 1; try out.append(alloc, words[wi]);
                    wi += 1; { const w = words[wi]; try out.append(alloc, idmap.get(w) orelse w); }
                }
                if (wi < end) { try out.append(alloc, words[wi]); wi += 1; }
            },
            'E' => {
                var in_str = true;
                while (wi < end and in_str) : (wi += 1) {
                    const w = words[wi]; try out.append(alloc, w);
                    if ((w & 0xFF) == 0 or ((w >> 8) & 0xFF) == 0 or ((w >> 16) & 0xFF) == 0 or ((w >> 24) & 0xFF) == 0) in_str = false;
                }
                while (wi < end) : (wi += 1) { const w = words[wi]; try out.append(alloc, idmap.get(w) orelse w); }
            },
            else => { while (wi < end) : (wi += 1) try out.append(alloc, words[wi]); },
        }
    }
    while (wi < end) : (wi += 1) try out.append(alloc, words[wi]);
}
