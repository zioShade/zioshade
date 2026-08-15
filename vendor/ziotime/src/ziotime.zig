//! Monotonic clock helpers for Zig.
//!
//! Zig 0.16 removed `std.time.Timer`, `std.time.Instant` and
//! `std.time.nanoTimestamp`. The monotonic clock now lives behind the `std.Io`
//! vtable and is read as `std.Io.Clock.awake.now(io)`, returning an
//! `Io.Timestamp`. That is a good change (timing is an I/O concern), but it
//! means every consumer that used to call `Timer.start()` must now be rewritten
//! and must thread an `Io` through.
//!
//! ziotime centralizes that churn so the fleet upgrades in one place:
//!
//! * `monotonicNanos(io)` / `monotonicMillis(io)` — read the monotonic clock.
//! * `Timer` — a minimal `start` / `read` / `readMillis` / `lap` / `reset`
//!   timer, the shape the old `std.time.Timer` callers want back.
//! * `MonotonicGuard` / `elapsedSince` — non-decreasing guards for callers that
//!   compute intervals from timestamps and must never see a backward step.
//!
//! Dual-version support: this file compiles on BOTH Zig 0.15.2 and 0.16, chosen
//! by CAPABILITY DETECTION (`std.Io.Clock` exists), not a version number — the
//! same approach zioshade's `compat.zig` uses. The untaken comptime branch is
//! not analyzed, so no version-only type leaks across builds. On 0.16 the clock
//! is `std.Io.Clock.awake`; on 0.15.2 it is a process-lifetime
//! `std.time.Timer`. Both yield the same non-decreasing nanosecond stream.
//!
//! I/O ergonomics: the reader functions and `Timer.start` take an `io` (an
//! `std.Io` on 0.16, `void` on 0.15.2) and — for `Timer` — store it. Nothing is
//! hidden behind a process-global `Io`; callers pass the same `io` the removed
//! sites used, so ziotime is a drop-in for `zappa`'s `monotonicMillis` /
//! `defaultNowNs` and `zioshade`'s `Timer`.
//!
//! Zero external dependencies.

const std = @import("std");
const builtin = @import("builtin");

/// Hard floor. Anything older than this fails to compile here with an
/// actionable message rather than a cryptic stdlib error later. Mirrors
/// zioshade's `compat.zig` floor so the two libraries share a support window.
pub const min_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
comptime {
    if (builtin.zig_version.order(min_zig) == .lt) {
        @compileError("ziotime requires Zig 0.15.2 or newer. See the README.");
    }
}

/// True when the monotonic clock lives behind `std.Io` (Zig 0.16+). Detected by
/// CAPABILITY (`std.Io.Clock` exists), not by version number: 0.15.2 has
/// `std.Io` but no `std.Io.Clock`, and a future release that keeps
/// `std.Io.Clock` still selects this branch with no code change.
/// COMPAT(0.15): when the floor moves to 0.16, this is always true and the
/// `std.time.Timer` fallbacks below can be deleted.
pub const is_0_16 = @hasDecl(std, "Io") and @hasDecl(std.Io, "Clock");

/// The I/O context type. On 0.16 this is `std.Io` (thread it through from a
/// `std.Io.Threaded` or any other implementation). On 0.15.2 the monotonic
/// clock needs no I/O context, so this is `void` — pass `{}`. Keeping it a
/// named alias lets consumer code stay version-agnostic: `ziotime.Io`.
pub const Io = if (is_0_16) std.Io else void;

/// Nanoseconds per millisecond.
pub const ns_per_ms: u64 = 1_000_000;
/// Nanoseconds per second.
pub const ns_per_s: u64 = 1_000_000_000;

// On 0.15.2 the monotonic source is a process-lifetime `std.time.Timer` started
// lazily on first use; its `read()` is monotonic nanoseconds from that epoch.
// A threadlocal keeps the read lock-free. `Timer.start()` can fail (no
// monotonic clock); we fall back to 0 rather than propagate, matching the
// clamp-to-non-negative contract of every reader here. On 0.16 this is `void`
// and never analyzed. COMPAT(0.15).
threadlocal var mono_epoch: if (is_0_16) void else ?std.time.Timer =
    if (is_0_16) {} else null;

/// Monotonic clock reading in nanoseconds, from an arbitrary fixed epoch.
///
/// Use it for measuring *elapsed* time (intervals), never as a wall clock — the
/// epoch is unspecified and the value is not comparable across processes. The
/// stream is non-decreasing: consecutive calls never go backwards (an NTP step
/// or manual clock change cannot produce a negative interval), though two calls
/// may return the same value.
///
/// On 0.16 this reads `std.Io.Clock.awake` (Linux `CLOCK_MONOTONIC`, macOS
/// `CLOCK_UPTIME_RAW`) via the supplied `io`. On 0.15.2 it reads a
/// process-lifetime `std.time.Timer`; `io` is `void` and ignored.
pub fn monotonicNanos(io: Io) u64 {
    if (is_0_16) {
        const ts = std.Io.Clock.awake.now(io);
        // `Io.Timestamp.nanoseconds` is `i96`; the awake clock counts from a
        // past point so it is non-negative and fits `u64` for ~584 years.
        // Clamp defensively so the contract ("never negative") is total.
        const n = ts.nanoseconds;
        return if (n <= 0) 0 else @intCast(n);
    } else {
        if (mono_epoch == null) {
            // No monotonic clock: degrade to 0 rather than fail. Every caller
            // treats the result as an interval basis, and the non-negative
            // clamps downstream keep a constant 0 harmless (all intervals 0).
            mono_epoch = std.time.Timer.start() catch return 0;
        }
        return mono_epoch.?.read();
    }
}

/// Monotonic clock reading in milliseconds — `monotonicNanos(io) / ns_per_ms`.
///
/// Convenience for the common "elapsed ms" case (e.g. zappa's per-connection
/// idle timers). Same epoch and non-decreasing guarantees as `monotonicNanos`.
pub fn monotonicMillis(io: Io) u64 {
    return monotonicNanos(io) / ns_per_ms;
}

/// Saturating interval: `later_ns - earlier_ns`, clamped to 0 when `later_ns`
/// is smaller (a backward step). Use it wherever you subtract two monotonic
/// readings and must never underflow a `u64` into a huge positive interval.
pub fn elapsedSince(earlier_ns: u64, later_ns: u64) u64 {
    return if (later_ns <= earlier_ns) 0 else later_ns - earlier_ns;
}

/// Minimal monotonic elapsed timer — the subset of the removed `std.time.Timer`
/// that fleet callers use (`start` / `read` / `readMillis` / `lap` / `reset`).
///
/// It captures the `io` at `start` and reuses it for every read, so a `Timer`
/// value is fully self-contained (no ambient/global `Io`). Backed by
/// `monotonicNanos`, so an NTP or manual clock step cannot yield a negative
/// interval; unlike the stdlib API, `start` cannot fail, so callers drop the
/// `try` / `catch`.
pub const Timer = struct {
    /// The captured I/O context (`std.Io` on 0.16, `void` on 0.15.2).
    io: Io,
    /// Monotonic nanoseconds captured at the last `start` / `reset` / `lap`.
    start_ns: u64,

    /// Start a timer anchored at the current monotonic reading.
    pub fn start(io: Io) Timer {
        return .{ .io = io, .start_ns = monotonicNanos(io) };
    }

    /// Nanoseconds elapsed since the last `start` / `reset` / `lap`. Never
    /// negative (clamped to 0 if the clock somehow stepped backward).
    pub fn read(self: Timer) u64 {
        return elapsedSince(self.start_ns, monotonicNanos(self.io));
    }

    /// Milliseconds elapsed since the last `start` / `reset` / `lap`.
    pub fn readMillis(self: Timer) u64 {
        return self.read() / ns_per_ms;
    }

    /// Re-anchor the timer to now; a subsequent `read` measures from here.
    pub fn reset(self: *Timer) void {
        self.start_ns = monotonicNanos(self.io);
    }

    /// Nanoseconds since the last `start` / `reset` / `lap`, and re-anchor to
    /// now in one call. Returns the elapsed interval (never negative).
    pub fn lap(self: *Timer) u64 {
        const now_ns = monotonicNanos(self.io);
        const elapsed = elapsedSince(self.start_ns, now_ns);
        self.start_ns = now_ns;
        return elapsed;
    }
};

/// A ratchet that makes an arbitrary timestamp stream non-decreasing.
///
/// `monotonicNanos` is already non-decreasing, but callers that mix in
/// caller-supplied or test-injected timestamps (e.g. a rate limiter fed an
/// external `now_ns`, like ziorate's clock guard) want a cheap guarantee that
/// time never appears to move backward. Feed each reading through `observe`;
/// it returns the largest value seen so far.
pub const MonotonicGuard = struct {
    /// The largest timestamp observed so far (0 before the first `observe`).
    last_ns: u64 = 0,

    /// Record `now_ns` and return the clamped, non-decreasing value: `now_ns`
    /// if it advanced the clock, otherwise the previous maximum.
    pub fn observe(self: *MonotonicGuard, now_ns: u64) u64 {
        if (now_ns > self.last_ns) self.last_ns = now_ns;
        return self.last_ns;
    }
};

// ==========================================================================
// Tests
// ==========================================================================

/// Run `checker` with a freshly-constructed `Io`, tearing it down after. Hides
/// the 0.15/0.16 split so each clock test stays a single line: on 0.16 it spins
/// a short-lived `std.Io.Threaded`; on 0.15.2 the io is `void`.
fn runWithIo(checker: fn (Io) anyerror!void) !void {
    if (is_0_16) {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        try checker(threaded.io());
    } else {
        try checker({});
    }
}

fn spinABit() void {
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 200_000) : (i += 1) acc +%= i;
    std.mem.doNotOptimizeAway(acc);
}

fn checkNonDecreasing(io: Io) !void {
    var prev = monotonicNanos(io);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const cur = monotonicNanos(io);
        try std.testing.expect(cur >= prev);
        prev = cur;
    }
}

fn checkTimer(io: Io) !void {
    var t = Timer.start(io);
    const e1 = t.read();
    spinABit();
    const e2 = t.read();
    // Elapsed is non-negative and never shrinks between reads of the same timer.
    try std.testing.expect(e2 >= e1);
    // Millis view is the nanosecond view divided by ns_per_ms (allow the two
    // separate reads to differ by at most 1 ms).
    try std.testing.expect(t.readMillis() >= (e2 / ns_per_ms) -| 1);
}

fn checkTimerResetLap(io: Io) !void {
    var t = Timer.start(io);
    spinABit();
    const lapped = t.lap();
    _ = lapped; // just exercising the path; timing is not asserted for equality
    // After a lap, the fresh interval starts from ~0 and only grows.
    const a = t.read();
    spinABit();
    const b = t.read();
    try std.testing.expect(b >= a);
    // reset re-anchors: immediately after, elapsed is tiny (<= the read below).
    t.reset();
    const after_reset = t.read();
    spinABit();
    try std.testing.expect(t.read() >= after_reset);
}

fn checkMillisConversion(io: Io) !void {
    // monotonicMillis == monotonicNanos / ns_per_ms at its own read instant,
    // which lies between two bracketing nanosecond reads. Floor division is
    // monotonic, so the millis value is within [n1/ms, n2/ms].
    const n1 = monotonicNanos(io);
    const ms = monotonicMillis(io);
    const n2 = monotonicNanos(io);
    try std.testing.expect(ms >= n1 / ns_per_ms);
    try std.testing.expect(ms <= n2 / ns_per_ms);
}

test "monotonicNanos is non-decreasing" {
    try runWithIo(checkNonDecreasing);
}

test "Timer measures non-negative, non-decreasing elapsed" {
    try runWithIo(checkTimer);
}

test "Timer lap and reset re-anchor the interval" {
    try runWithIo(checkTimerResetLap);
}

test "monotonicMillis is monotonicNanos divided by ns_per_ms" {
    try runWithIo(checkMillisConversion);
}

test "elapsedSince clamps a backward clock to zero" {
    try std.testing.expectEqual(@as(u64, 5), elapsedSince(10, 15));
    try std.testing.expectEqual(@as(u64, 0), elapsedSince(15, 15));
    try std.testing.expectEqual(@as(u64, 0), elapsedSince(15, 10));
    // No underflow into a huge positive interval.
    try std.testing.expectEqual(@as(u64, 0), elapsedSince(std.math.maxInt(u64), 0));
}

test "MonotonicGuard never decreases across observations" {
    var g: MonotonicGuard = .{};
    try std.testing.expectEqual(@as(u64, 100), g.observe(100));
    try std.testing.expectEqual(@as(u64, 100), g.observe(50)); // backward: clamped
    try std.testing.expectEqual(@as(u64, 100), g.observe(100)); // equal: held
    try std.testing.expectEqual(@as(u64, 250), g.observe(250)); // forward: advances
    try std.testing.expectEqual(@as(u64, 250), g.last_ns);
}

test "ns_per_ms and ns_per_s constants are consistent" {
    try std.testing.expectEqual(@as(u64, 1000), ns_per_s / ns_per_ms);
}
