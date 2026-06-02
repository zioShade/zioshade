// SPDX-License-Identifier: MIT OR Apache-2.0
//! CFG structurization — Phase 1: control-flow analysis scaffold.
//!
//! See docs/specs/2026-06-02-cfg-structurization.md. This phase provides the
//! *analysis* primitives (CFG, dominator tree, back-edge / loop-header detection,
//! reducibility classification) with NO module mutation and NO wiring into the
//! cross-compile path — it is pure, unit-tested analysis that cannot change any
//! backend output. Merge-info recovery (the behavior-changing part) lands in
//! later phases, gated by strip-and-recover round-trip + oracle differentials.
//!
//! The core operates on a backend-agnostic `Cfg` (blocks + successor lists) so it
//! can be unit-tested on hand-built graphs without real SPIR-V; a thin SPIR-V
//! adapter is added in Phase 2 when the recovered merge info is actually emitted.

const std = @import("std");
const common = @import("spirv_cross_common.zig");
const spirv = @import("spirv.zig");
const Instruction = common.Instruction;

/// A control-flow graph: `n` blocks numbered `0..n`, `entry` is the start block,
/// `succ[b]` lists the successor block indices of block `b`.
pub const Cfg = struct {
    n: usize,
    entry: usize,
    succ: []const []const usize,
};

/// A recorded structured selection (from an existing `OpSelectionMerge`): the
/// header block and the merge block it names. Used as ground truth by the
/// strip-and-recover validation (does `computePostDom` re-derive `merge`?).
pub const SelMerge = struct { header: usize, merge: usize };

/// A CFG built from a SPIR-V function body, plus the block↔label mapping and the
/// merge blocks the body's `OpSelectionMerge`s actually named. Caller owns it
/// (`deinit`).
pub const SpirvCfg = struct {
    cfg: Cfg,
    block_label: []u32, // block index → OpLabel result id
    succ_store: [][]usize, // backing storage for cfg.succ entries
    succ_view: [][]const usize, // the slice cfg.succ points at
    sel_merges: []SelMerge, // headers that ALREADY carry an OpSelectionMerge
    cond_headers: []usize, // blocks ending in OpBranchConditional / OpSwitch
    alloc: std.mem.Allocator,

    pub fn deinit(self: *SpirvCfg) void {
        for (self.succ_store) |s| self.alloc.free(s);
        self.alloc.free(self.succ_store);
        self.alloc.free(self.succ_view);
        self.alloc.free(self.block_label);
        self.alloc.free(self.sel_merges);
        self.alloc.free(self.cond_headers);
    }

    fn hasMerge(self: *const SpirvCfg, header: usize) bool {
        for (self.sel_merges) |m| if (m.header == header) return true;
        return false;
    }
};

/// A merge-info insertion the structurizer would synthesize: block `header`
/// (currently lacking an `OpSelectionMerge`) gets `OpSelectionMerge %merge_label`.
pub const Insertion = struct { header_label: u32, merge_label: u32 };

/// Decide the `OpSelectionMerge`s needed to structurize the selection headers of a
/// function body that lacks them. Pure: computes the insertions (header→merge),
/// or returns `error.UnstructuredControlFlow` if any conditional header cannot be
/// given a structured merge (irreducible CFG, or a header whose successors do not
/// reconverge on a real block — ipdom is the function EXIT, e.g. an early-return
/// arm). Does NOT mutate; the caller (a later phase) applies the insertions.
///
/// Headers that already carry an `OpSelectionMerge` and loop headers are left
/// alone (loop merges are recovered separately, Phase 3). Caller owns the result.
pub fn recoverSelectionMerges(alloc: std.mem.Allocator, insts: []const Instruction) ![]Insertion {
    var sc = try buildCfgFromBody(alloc, insts);
    defer sc.deinit();

    var dom = try analyze(alloc, sc.cfg);
    defer dom.deinit(alloc);
    if (!dom.reducible) return error.UnstructuredControlFlow;

    const ipdom = try computePostDom(alloc, sc.cfg);
    defer alloc.free(ipdom);

    var out = std.ArrayList(Insertion).empty;
    errdefer out.deinit(alloc);
    for (sc.cond_headers) |h| {
        if (sc.hasMerge(h)) continue; // already structured
        if (dom.is_loop_header[h]) continue; // loop merge = Phase 3
        const m = ipdom[h];
        if (m == EXIT or m == Analysis.NONE) {
            // successors don't reconverge on a real block (e.g. an arm returns) →
            // not a plain structured if/switch; refuse rather than guess. The
            // errdefer frees `out`.
            return error.UnstructuredControlFlow;
        }
        try out.append(alloc, .{ .header_label = sc.block_label[h], .merge_label = sc.block_label[m] });
    }
    return out.toOwnedSlice(alloc);
}

/// Build a `Cfg` from a SPIR-V function body (`insts` = the instructions from the
/// first `OpLabel` through the terminators, e.g. a single function). Blocks start
/// at `OpLabel`; successors come from the terminator (`OpBranch` /
/// `OpBranchConditional` / `OpSwitch`; `OpReturn`/`OpKill`/`OpUnreachable` = sink).
/// Existing `OpSelectionMerge`s are recorded (as ground truth) but their edges are
/// NOT added to the CFG — the CFG is the raw branch graph, exactly what the
/// recovery pass sees for unstructured input. Pure; never mutates input.
pub fn buildCfgFromBody(alloc: std.mem.Allocator, insts: []const Instruction) !SpirvCfg {
    // Pass 1: enumerate blocks (OpLabel result ids), in order.
    var labels = std.ArrayList(u32).empty;
    errdefer labels.deinit(alloc);
    var idx_of = std.AutoHashMap(u32, usize).init(alloc);
    defer idx_of.deinit();
    for (insts) |ins| {
        if (ins.op == .Label and ins.words.len >= 2) {
            try idx_of.put(ins.words[1], labels.items.len);
            try labels.append(alloc, ins.words[1]);
        }
    }
    const n = labels.items.len;

    const succ_store = try alloc.alloc([]usize, n);
    const assigned = try alloc.alloc(bool, n);
    @memset(assigned, false);
    defer alloc.free(assigned);
    errdefer {
        for (0..n) |i| if (assigned[i]) alloc.free(succ_store[i]);
        alloc.free(succ_store);
    }
    var sel = std.ArrayList(SelMerge).empty;
    errdefer sel.deinit(alloc);
    var cond = std.ArrayList(usize).empty;
    errdefer cond.deinit(alloc);

    const setSucc = struct {
        fn f(a: std.mem.Allocator, store: [][]usize, asn: []bool, b: usize, items: []const usize) !void {
            store[b] = try a.dupe(usize, items);
            asn[b] = true;
        }
    }.f;

    // Pass 2: walk blocks, fill successors + record selection merges.
    var cur: ?usize = null;
    var pending_merge: ?u32 = null; // merge label from an OpSelectionMerge in cur block
    var tmp = std.ArrayList(usize).empty;
    defer tmp.deinit(alloc);

    for (insts) |ins| {
        switch (ins.op) {
            .Label => {
                cur = idx_of.get(ins.words[1]).?;
                pending_merge = null;
            },
            .SelectionMerge => {
                if (ins.words.len >= 2) pending_merge = ins.words[1];
            },
            .Branch => {
                if (cur) |b| {
                    tmp.clearRetainingCapacity();
                    if (ins.words.len >= 2) if (idx_of.get(ins.words[1])) |t| try tmp.append(alloc, t);
                    try setSucc(alloc, succ_store, assigned, b, tmp.items);
                    cur = null;
                }
            },
            .BranchConditional => {
                if (cur) |b| {
                    tmp.clearRetainingCapacity();
                    if (ins.words.len >= 4) {
                        if (idx_of.get(ins.words[2])) |t| try tmp.append(alloc, t);
                        if (idx_of.get(ins.words[3])) |f| try tmp.append(alloc, f);
                    }
                    try setSucc(alloc, succ_store, assigned, b, tmp.items);
                    try cond.append(alloc, b);
                    if (pending_merge) |m| if (idx_of.get(m)) |mi| try sel.append(alloc, .{ .header = b, .merge = mi });
                    cur = null;
                }
            },
            .Switch => {
                if (cur) |b| {
                    tmp.clearRetainingCapacity();
                    // words[2] = default label, then (literal, label) pairs from words[3].
                    if (ins.words.len >= 3) if (idx_of.get(ins.words[2])) |d| try tmp.append(alloc, d);
                    var w: usize = 4;
                    while (w < ins.words.len) : (w += 2) {
                        if (idx_of.get(ins.words[w])) |t| {
                            var seen = false;
                            for (tmp.items) |e| if (e == t) {
                                seen = true;
                                break;
                            };
                            if (!seen) try tmp.append(alloc, t);
                        }
                    }
                    try setSucc(alloc, succ_store, assigned, b, tmp.items);
                    try cond.append(alloc, b);
                    if (pending_merge) |m| if (idx_of.get(m)) |mi| try sel.append(alloc, .{ .header = b, .merge = mi });
                    cur = null;
                }
            },
            .Return, .ReturnValue, .Kill, .Unreachable => {
                if (cur) |b| {
                    try setSucc(alloc, succ_store, assigned, b, &.{});
                    cur = null;
                }
            },
            else => {},
        }
    }
    // Any block without an explicit terminator (malformed SPIR-V) → sink.
    for (0..n) |b| {
        if (!assigned[b]) try setSucc(alloc, succ_store, assigned, b, &.{});
    }

    const succ_view = try alloc.alloc([]const usize, n);
    errdefer alloc.free(succ_view);
    for (0..n) |b| succ_view[b] = succ_store[b];

    return .{
        .cfg = .{ .n = n, .entry = 0, .succ = succ_view },
        .block_label = try labels.toOwnedSlice(alloc),
        .succ_store = succ_store,
        .succ_view = succ_view,
        .sel_merges = try sel.toOwnedSlice(alloc),
        .cond_headers = try cond.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

/// Result of `analyze` — owned by the caller via `arena`/allocator passed in.
pub const Analysis = struct {
    /// Immediate dominator of each block. `idom[entry] == entry`. Unreachable
    /// blocks have `idom == NONE`.
    idom: []usize,
    /// Reverse-postorder numbering: `rpo_num[b]` is `b`'s position in RPO (lower =
    /// earlier). Unreachable blocks get `UNREACHABLE`.
    rpo_num: []usize,
    /// True iff `b` is the target of a back-edge (a loop header).
    is_loop_header: []bool,
    /// True iff the CFG is reducible (every retreating DFS edge is a back-edge,
    /// i.e. its target dominates its source). Irreducible CFGs cannot be expressed
    /// as structured control flow and must be honest-errored by later phases.
    reducible: bool,

    pub const NONE = std.math.maxInt(usize);
    pub const UNREACHABLE = std.math.maxInt(usize);

    pub fn deinit(self: *Analysis, alloc: std.mem.Allocator) void {
        alloc.free(self.idom);
        alloc.free(self.rpo_num);
        alloc.free(self.is_loop_header);
    }

    /// Does block `a` dominate block `b`? (Every path from entry to `b` goes
    /// through `a`.) Walks the idom chain from `b` to the entry.
    pub fn dominates(self: *const Analysis, a: usize, b: usize) bool {
        if (self.idom[b] == NONE) return false; // b unreachable
        var x = b;
        while (true) {
            if (x == a) return true;
            if (x == self.idom[x]) return false; // reached entry without hitting a
            x = self.idom[x];
        }
    }
};

/// Build the analysis (dominators + RPO + loop headers + reducibility) for `cfg`.
/// Caller owns the returned `Analysis` (`deinit`). Pure: never mutates input.
pub fn analyze(alloc: std.mem.Allocator, cfg: Cfg) !Analysis {
    const n = cfg.n;

    // --- 1. Reverse postorder via iterative DFS, plus retreating-edge detection.
    const rpo_num = try alloc.alloc(usize, n);
    errdefer alloc.free(rpo_num);
    @memset(rpo_num, Analysis.UNREACHABLE);

    const order = try alloc.alloc(usize, n); // postorder accumulation
    defer alloc.free(order);
    var order_len: usize = 0;

    // DFS state: 0=white(unseen), 1=grey(on stack), 2=black(done).
    const color = try alloc.alloc(u2, n);
    defer alloc.free(color);
    @memset(color, 0);

    // Explicit stack of (block, next-successor-index) to avoid recursion limits.
    const Frame = struct { b: usize, i: usize };
    const stack = try alloc.alloc(Frame, n);
    defer alloc.free(stack);

    // Track retreating edges (to a grey node) and whether each is a back-edge.
    // We can only test "target dominates source" after dominators are computed,
    // so record retreating edges now and classify after.
    var retreating = std.ArrayList([2]usize).empty;
    defer retreating.deinit(alloc);

    var sp: usize = 0;
    stack[sp] = .{ .b = cfg.entry, .i = 0 };
    color[cfg.entry] = 1;
    while (sp + 1 > 0 and sp != std.math.maxInt(usize)) {
        const fr = &stack[sp];
        if (fr.i < cfg.succ[fr.b].len) {
            const s = cfg.succ[fr.b][fr.i];
            fr.i += 1;
            if (color[s] == 0) {
                color[s] = 1;
                sp += 1;
                stack[sp] = .{ .b = s, .i = 0 };
            } else if (color[s] == 1) {
                // edge to a grey (on-stack) node = retreating edge
                try retreating.append(alloc, .{ fr.b, s });
            }
        } else {
            color[fr.b] = 2;
            order[order_len] = fr.b;
            order_len += 1;
            if (sp == 0) break;
            sp -= 1;
        }
    }

    // RPO number = reverse of postorder.
    var k: usize = 0;
    while (k < order_len) : (k += 1) {
        rpo_num[order[order_len - 1 - k]] = k;
    }

    // --- 2. Predecessors (inverse of succ), reachable blocks only.
    var preds = try alloc.alloc(std.ArrayList(usize), n);
    defer {
        for (preds) |*p| p.deinit(alloc);
        alloc.free(preds);
    }
    for (preds) |*p| p.* = std.ArrayList(usize).empty;
    for (0..n) |b| {
        if (rpo_num[b] == Analysis.UNREACHABLE) continue;
        for (cfg.succ[b]) |s| {
            if (rpo_num[s] == Analysis.UNREACHABLE) continue;
            try preds[s].append(alloc, b);
        }
    }

    // --- 3. Dominators (Cooper–Harvey–Kennedy iterative, over RPO).
    const idom = try alloc.alloc(usize, n);
    errdefer alloc.free(idom);
    @memset(idom, Analysis.NONE);
    idom[cfg.entry] = cfg.entry;

    // RPO sequence of reachable blocks (excluding entry), ascending rpo_num.
    const rpo_seq = try alloc.alloc(usize, order_len);
    defer alloc.free(rpo_seq);
    for (0..n) |b| {
        if (rpo_num[b] != Analysis.UNREACHABLE) rpo_seq[rpo_num[b]] = b;
    }

    const Helper = struct {
        fn intersect(rn: []const usize, id: []const usize, a0: usize, b0: usize) usize {
            var a = a0;
            var b = b0;
            while (a != b) {
                while (rn[a] > rn[b]) a = id[a];
                while (rn[b] > rn[a]) b = id[b];
            }
            return a;
        }
    };

    var changed = true;
    while (changed) {
        changed = false;
        // process in RPO, skipping entry (rpo_seq[0]).
        for (rpo_seq[1..]) |b| {
            var new_idom: usize = Analysis.NONE;
            for (preds[b].items) |p| {
                if (idom[p] == Analysis.NONE) continue; // not yet processed
                new_idom = if (new_idom == Analysis.NONE) p else Helper.intersect(rpo_num, idom, p, new_idom);
            }
            if (new_idom != Analysis.NONE and idom[b] != new_idom) {
                idom[b] = new_idom;
                changed = true;
            }
        }
    }

    // --- 4. Classify retreating edges → back-edges / loop headers / reducibility.
    const is_loop_header = try alloc.alloc(bool, n);
    errdefer alloc.free(is_loop_header);
    @memset(is_loop_header, false);

    var tmp = Analysis{ .idom = idom, .rpo_num = rpo_num, .is_loop_header = is_loop_header, .reducible = true };
    for (retreating.items) |e| {
        const src = e[0];
        const dst = e[1];
        if (tmp.dominates(dst, src)) {
            // back-edge → dst is a loop header
            is_loop_header[dst] = true;
        } else {
            // retreating but not dominating → irreducible
            tmp.reducible = false;
        }
    }

    return tmp;
}

/// Sentinel returned by `computePostDom` for a block whose only post-dominator is
/// the (virtual) function exit — i.e. its successors do not reconverge on a real
/// block before the function returns. For a selection header this means the
/// construct is NOT a simple structured `if`-with-merge (e.g. one arm returns),
/// so merge-info recovery must honest-error rather than guess (spec §4).
pub const EXIT = std.math.maxInt(usize) - 1;

/// Immediate post-dominator of every block, in the original block numbering.
/// `ipdom[b]` is the nearest block that lies on every path from `b` to the
/// function exit; `EXIT` if that is only the virtual exit; `Analysis.NONE` if `b`
/// cannot reach any exit. Implemented as forward dominators on the reverse CFG
/// rooted at a synthetic exit node — so it reuses `analyze` and shares its
/// correctness. Pure: never mutates input. Caller owns the returned slice.
pub fn computePostDom(alloc: std.mem.Allocator, cfg: Cfg) ![]usize {
    const n = cfg.n;
    const vexit = n; // synthetic exit node index

    // Reverse adjacency, plus virtual-exit → every sink (block with no real succ).
    var rsucc = try alloc.alloc(std.ArrayList(usize), n + 1);
    defer {
        for (rsucc) |*r| r.deinit(alloc);
        alloc.free(rsucc);
    }
    for (rsucc) |*r| r.* = std.ArrayList(usize).empty;
    for (0..n) |b| {
        if (cfg.succ[b].len == 0) {
            // sink (OpReturn / OpKill / OpUnreachable): exit flows here in reverse
            try rsucc[vexit].append(alloc, b);
        }
        for (cfg.succ[b]) |s| {
            try rsucc[s].append(alloc, b); // reverse edge s -> b
        }
    }

    const rslices = try alloc.alloc([]const usize, n + 1);
    defer alloc.free(rslices);
    for (0..n + 1) |i| rslices[i] = rsucc[i].items;

    var ar = try analyze(alloc, .{ .n = n + 1, .entry = vexit, .succ = rslices });
    defer ar.deinit(alloc);

    const ipdom = try alloc.alloc(usize, n);
    for (0..n) |b| {
        const id = ar.idom[b];
        ipdom[b] = if (id == Analysis.NONE) Analysis.NONE else if (id == vexit) EXIT else id;
    }
    return ipdom;
}

/// Apply recovered `insertions` to a SPIR-V word stream: splice an
/// `OpSelectionMerge %merge None` immediately before the terminator of each named
/// header block. Returns a NEW owned word stream (a copy even when there are no
/// insertions, so the caller frees uniformly). Pure: never mutates `words`.
///
/// The result is structured SPIR-V the existing backends accept unchanged; it
/// must remain `spirv-val`-clean (the splice only adds well-formed
/// `OpSelectionMerge`s whose merge ids reference existing blocks).
pub fn spliceSelectionMerges(alloc: std.mem.Allocator, words: []const u32, insertions: []const Insertion) ![]u32 {
    if (words.len < 5 or words[0] != spirv.MAGIC) return error.InvalidSpirv;

    var map = std.AutoHashMap(u32, u32).init(alloc);
    defer map.deinit();
    for (insertions) |ins| try map.put(ins.header_label, ins.merge_label);

    var out = std.ArrayList(u32).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, words[0..5]); // SPIR-V header (magic, version, gen, bound, schema)

    const SEL = @intFromEnum(spirv.Op.SelectionMerge);
    const LABEL = @intFromEnum(spirv.Op.Label);
    const BRC = @intFromEnum(spirv.Op.BranchConditional);
    const SWITCH = @intFromEnum(spirv.Op.Switch);

    var i: usize = 5;
    var cur_label: u32 = 0;
    while (i < words.len) {
        const hw = words[i];
        const wc: usize = hw >> 16;
        const op: u16 = @truncate(hw & 0xFFFF);
        if (wc == 0 or i + wc > words.len) return error.InvalidSpirv;

        if (op == LABEL and wc >= 2) {
            cur_label = words[i + 1];
        } else if (op == BRC or op == SWITCH) {
            if (map.get(cur_label)) |merge| {
                try out.append(alloc, (@as(u32, 3) << 16) | @as(u32, SEL));
                try out.append(alloc, merge);
                try out.append(alloc, 0); // SelectionControl = None
            }
        }
        try out.appendSlice(alloc, words[i .. i + wc]);
        i += wc;
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests — hand-built CFGs with known dominator / loop / reducibility answers.
// ---------------------------------------------------------------------------
const testing = std.testing;

fn buildCfg(comptime n: usize, succ: []const []const usize, entry: usize) Cfg {
    return .{ .n = n, .entry = entry, .succ = succ };
}

test "cfg: straight line — each block dominates the next" {
    // 0 -> 1 -> 2
    const succ = [_][]const usize{ &.{1}, &.{2}, &.{} };
    var a = try analyze(testing.allocator, buildCfg(3, &succ, 0));
    defer a.deinit(testing.allocator);
    try testing.expect(a.reducible);
    try testing.expect(a.dominates(0, 2));
    try testing.expect(a.dominates(1, 2));
    try testing.expect(!a.dominates(2, 1));
    try testing.expectEqual(@as(usize, 0), a.idom[1]);
    try testing.expectEqual(@as(usize, 1), a.idom[2]);
    try testing.expect(!a.is_loop_header[0] and !a.is_loop_header[1] and !a.is_loop_header[2]);
}

test "cfg: diamond — header dominates merge, arms do not" {
    // 0 -> {1,2} -> 3
    const succ = [_][]const usize{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} };
    var a = try analyze(testing.allocator, buildCfg(4, &succ, 0));
    defer a.deinit(testing.allocator);
    try testing.expect(a.reducible);
    try testing.expectEqual(@as(usize, 0), a.idom[3]); // merge's idom is the header
    try testing.expect(a.dominates(0, 3));
    try testing.expect(!a.dominates(1, 3)); // arm does not dominate the merge
    try testing.expect(!a.is_loop_header[0]);
}

test "cfg: simple loop — back-edge target is a loop header, CFG reducible" {
    // 0 -> 1 -> 2 -> 1 (back), 2 -> 3
    const succ = [_][]const usize{ &.{1}, &.{2}, &.{ 1, 3 }, &.{} };
    var a = try analyze(testing.allocator, buildCfg(4, &succ, 0));
    defer a.deinit(testing.allocator);
    try testing.expect(a.reducible);
    try testing.expect(a.is_loop_header[1]); // 2->1 back-edge, 1 dominates 2
    try testing.expect(!a.is_loop_header[2]);
    try testing.expect(a.dominates(1, 2));
}

test "cfg: irreducible — two-entry loop is detected, not mislabeled" {
    // 0 -> {1,2}; 1 -> 2; 2 -> 1.  Loop {1,2} has two entries (from 0 directly to
    // both), so neither 1 nor 2 dominates the other → retreating edge is not a
    // back-edge → irreducible.
    const succ = [_][]const usize{ &.{ 1, 2 }, &.{2}, &.{1} };
    var a = try analyze(testing.allocator, buildCfg(3, &succ, 0));
    defer a.deinit(testing.allocator);
    try testing.expect(!a.reducible);
}

test "cfg: unreachable block has no dominator and is ignored" {
    // 0 -> 1 ; block 2 unreachable
    const succ = [_][]const usize{ &.{1}, &.{}, &.{1} };
    var a = try analyze(testing.allocator, buildCfg(3, &succ, 0));
    defer a.deinit(testing.allocator);
    try testing.expect(a.reducible);
    try testing.expectEqual(Analysis.NONE, a.idom[2]);
    try testing.expect(!a.dominates(0, 2)); // unreachable: dominates() is false
}

test "postdom: diamond merge post-dominates the header (= structured merge block)" {
    // 0 -> {1,2} -> 3.  Block 3 is where both arms reconverge → the if-merge.
    const succ = [_][]const usize{ &.{ 1, 2 }, &.{3}, &.{3}, &.{} };
    const ipdom = try computePostDom(testing.allocator, buildCfg(4, &succ, 0));
    defer testing.allocator.free(ipdom);
    try testing.expectEqual(@as(usize, 3), ipdom[0]); // header's merge = block 3
    try testing.expectEqual(@as(usize, 3), ipdom[1]);
    try testing.expectEqual(@as(usize, 3), ipdom[2]);
    try testing.expectEqual(EXIT, ipdom[3]); // 3 reconverges only at the exit
}

test "postdom: straight line — each block's ipdom is the next" {
    const succ = [_][]const usize{ &.{1}, &.{2}, &.{} };
    const ipdom = try computePostDom(testing.allocator, buildCfg(3, &succ, 0));
    defer testing.allocator.free(ipdom);
    try testing.expectEqual(@as(usize, 1), ipdom[0]);
    try testing.expectEqual(@as(usize, 2), ipdom[1]);
    try testing.expectEqual(EXIT, ipdom[2]);
}

test "postdom: arm returns early → header ipdom is EXIT (NOT a simple merge)" {
    // 0 -> {1,2}; 1 -> 3 ; 2 -> return (sink).  Paths from 0 do NOT reconverge on
    // a real block, so ipdom[0] == EXIT — the signal that this is not expressible
    // as a plain if-with-merge and merge recovery must honest-error.
    const succ = [_][]const usize{ &.{ 1, 2 }, &.{3}, &.{}, &.{} };
    const ipdom = try computePostDom(testing.allocator, buildCfg(4, &succ, 0));
    defer testing.allocator.free(ipdom);
    try testing.expectEqual(EXIT, ipdom[0]);
}

test "adapter+recover: if-else body — CFG built and ipdom re-derives the merge" {
    // Hand-built SPIR-V body for: if (cond) {then} else {else} ; merge ; return.
    // Labels: 1=entry 2=then 3=else 4=merge → block indices 0,1,2,3.
    // words[0] is the (ignored) opcode header; operands follow.
    const a = testing.allocator;
    const lbl1 = [_]u32{ 0, 1 };
    const selm = [_]u32{ 0, 4, 0 }; // OpSelectionMerge merge=4 control=0
    const brc = [_]u32{ 0, 99, 2, 3 }; // OpBranchConditional cond=99 true=2 false=3
    const lbl2 = [_]u32{ 0, 2 };
    const br2 = [_]u32{ 0, 4 };
    const lbl3 = [_]u32{ 0, 3 };
    const br3 = [_]u32{ 0, 4 };
    const lbl4 = [_]u32{ 0, 4 };
    const ret = [_]u32{0};
    const insts = [_]Instruction{
        .{ .op = .Label, .words = &lbl1 },
        .{ .op = .SelectionMerge, .words = &selm },
        .{ .op = .BranchConditional, .words = &brc },
        .{ .op = .Label, .words = &lbl2 },
        .{ .op = .Branch, .words = &br2 },
        .{ .op = .Label, .words = &lbl3 },
        .{ .op = .Branch, .words = &br3 },
        .{ .op = .Label, .words = &lbl4 },
        .{ .op = .Return, .words = &ret },
    };

    var sc = try buildCfgFromBody(a, &insts);
    defer sc.deinit();

    try testing.expectEqual(@as(usize, 4), sc.cfg.n);
    // entry(0) → {then(1), else(2)}
    try testing.expectEqual(@as(usize, 2), sc.cfg.succ[0].len);
    try testing.expectEqual(@as(usize, 1), sc.cfg.succ[0][0]);
    try testing.expectEqual(@as(usize, 2), sc.cfg.succ[0][1]);
    // then(1) → {merge(3)} ; else(2) → {merge(3)} ; merge(3) → sink
    try testing.expectEqual(@as(usize, 3), sc.cfg.succ[1][0]);
    try testing.expectEqual(@as(usize, 3), sc.cfg.succ[2][0]);
    try testing.expectEqual(@as(usize, 0), sc.cfg.succ[3].len);

    // Ground truth: the body's OpSelectionMerge named header=0, merge=3.
    try testing.expectEqual(@as(usize, 1), sc.sel_merges.len);
    try testing.expectEqual(@as(usize, 0), sc.sel_merges[0].header);
    try testing.expectEqual(@as(usize, 3), sc.sel_merges[0].merge);

    // STRIP-AND-RECOVER: computePostDom (which never saw the OpSelectionMerge)
    // must re-derive the same merge block as the recorded ground truth.
    const ipdom = try computePostDom(a, sc.cfg);
    defer a.free(ipdom);
    try testing.expectEqual(sc.sel_merges[0].merge, ipdom[sc.sel_merges[0].header]);
}

test "recover: if-else WITHOUT a merge → synthesizes header→merge insertion" {
    // Same if-else as above but with NO OpSelectionMerge (the unstructured case).
    // recoverSelectionMerges must propose `OpSelectionMerge %4` on header %1.
    const a = testing.allocator;
    const lbl1 = [_]u32{ 0, 1 };
    const brc = [_]u32{ 0, 99, 2, 3 };
    const lbl2 = [_]u32{ 0, 2 };
    const br2 = [_]u32{ 0, 4 };
    const lbl3 = [_]u32{ 0, 3 };
    const br3 = [_]u32{ 0, 4 };
    const lbl4 = [_]u32{ 0, 4 };
    const ret = [_]u32{0};
    const insts = [_]Instruction{
        .{ .op = .Label, .words = &lbl1 },
        .{ .op = .BranchConditional, .words = &brc },
        .{ .op = .Label, .words = &lbl2 },
        .{ .op = .Branch, .words = &br2 },
        .{ .op = .Label, .words = &lbl3 },
        .{ .op = .Branch, .words = &br3 },
        .{ .op = .Label, .words = &lbl4 },
        .{ .op = .Return, .words = &ret },
    };
    const ins = try recoverSelectionMerges(a, &insts);
    defer a.free(ins);
    try testing.expectEqual(@as(usize, 1), ins.len);
    try testing.expectEqual(@as(u32, 1), ins[0].header_label);
    try testing.expectEqual(@as(u32, 4), ins[0].merge_label);
}

test "splice: inserts OpSelectionMerge before the header terminator; no-op copies" {
    const a = testing.allocator;
    const L: u32 = @intFromEnum(spirv.Op.Label);
    const BRC: u32 = @intFromEnum(spirv.Op.BranchConditional);
    const BR: u32 = @intFromEnum(spirv.Op.Branch);
    const RET: u32 = @intFromEnum(spirv.Op.Return);
    const SEL: u32 = @intFromEnum(spirv.Op.SelectionMerge);
    // Minimal SPIR-V: 5-word header + an if-else body with NO OpSelectionMerge.
    const words = [_]u32{
        spirv.MAGIC, 0x10000, 0, 10, 0, // header
        (2 << 16) | L,   1, // OpLabel %1
        (4 << 16) | BRC, 99, 2, 3, // OpBranchConditional %99 %2 %3
        (2 << 16) | L,   2,
        (2 << 16) | BR,  4,
        (2 << 16) | L,   3,
        (2 << 16) | BR,  4,
        (2 << 16) | L,   4,
        (1 << 16) | RET,
    };
    // No-op: empty insertions → byte-identical copy.
    const same = try spliceSelectionMerges(a, &words, &.{});
    defer a.free(same);
    try testing.expectEqualSlices(u32, &words, same);

    // Insert OpSelectionMerge %4 on header %1.
    const ins = [_]Insertion{.{ .header_label = 1, .merge_label = 4 }};
    const out = try spliceSelectionMerges(a, &words, &ins);
    defer a.free(out);
    try testing.expectEqual(words.len + 3, out.len); // one 3-word OpSelectionMerge added

    // Locate the spliced OpSelectionMerge and check its operands + position.
    var found = false;
    for (out, 0..) |w, k| {
        if ((w & 0xFFFF) == SEL) {
            try testing.expectEqual((@as(u32, 3) << 16) | SEL, w);
            try testing.expectEqual(@as(u32, 4), out[k + 1]); // merge label
            try testing.expectEqual(@as(u32, 0), out[k + 2]); // SelectionControl None
            // immediately followed by the BranchConditional it guards
            try testing.expectEqual((@as(u32, 4) << 16) | BRC, out[k + 3]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "recover: arm returns early → honest-error (no structured merge)" {
    // if (cond) { ... -> 4 } else { return }.  The arms do not reconverge on a
    // real block, so this is not a plain if-with-merge → honest-error, never guess.
    const a = testing.allocator;
    const lbl1 = [_]u32{ 0, 1 };
    const brc = [_]u32{ 0, 99, 2, 3 };
    const lbl2 = [_]u32{ 0, 2 };
    const br2 = [_]u32{ 0, 4 };
    const lbl3 = [_]u32{ 0, 3 };
    const ret3 = [_]u32{0};
    const lbl4 = [_]u32{ 0, 4 };
    const ret4 = [_]u32{0};
    const insts = [_]Instruction{
        .{ .op = .Label, .words = &lbl1 },
        .{ .op = .BranchConditional, .words = &brc },
        .{ .op = .Label, .words = &lbl2 },
        .{ .op = .Branch, .words = &br2 },
        .{ .op = .Label, .words = &lbl3 },
        .{ .op = .Return, .words = &ret3 },
        .{ .op = .Label, .words = &lbl4 },
        .{ .op = .Return, .words = &ret4 },
    };
    try testing.expectError(error.UnstructuredControlFlow, recoverSelectionMerges(a, &insts));
}

test "postdom: loop — immediate post-dom is the next in-loop block, not the merge" {
    // 0 -> 1 -> 2 -> {1 (back), 3} -> end.  Every path from header 1 to exit goes
    // 1 -> 2 (1's only successor) -> ... -> 3, so the IMMEDIATE post-dom of 1 is 2,
    // and ipdom[2] == 3. The loop *merge/break* target (3) is NOT simply
    // ipdom[header] — loop-merge derivation (the break-edge convergence) is the
    // nuanced Phase 3 case; selection-merge (Phase 2) is the clean ipdom[header].
    const succ = [_][]const usize{ &.{1}, &.{2}, &.{ 1, 3 }, &.{} };
    const ipdom = try computePostDom(testing.allocator, buildCfg(4, &succ, 0));
    defer testing.allocator.free(ipdom);
    try testing.expectEqual(@as(usize, 2), ipdom[1]);
    try testing.expectEqual(@as(usize, 3), ipdom[2]); // exiting block's ipdom = break target
}
