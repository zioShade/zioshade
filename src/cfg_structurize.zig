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

/// A control-flow graph: `n` blocks numbered `0..n`, `entry` is the start block,
/// `succ[b]` lists the successor block indices of block `b`.
pub const Cfg = struct {
    n: usize,
    entry: usize,
    succ: []const []const usize,
};

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
