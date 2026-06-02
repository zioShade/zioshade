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
