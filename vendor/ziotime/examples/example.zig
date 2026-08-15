const std = @import("std");
const ziotime = @import("ziotime");

pub fn main() !void {
    // On 0.16 the monotonic clock is read through an `std.Io`. A short-lived
    // `Threaded` implementation is fine for a one-shot CLI; a real service
    // threads its own `io` in instead.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Time a chunk of work with the Timer.
    var timer = ziotime.Timer.start(io);
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 5_000_000) : (i += 1) acc +%= i;
    std.mem.doNotOptimizeAway(acc);

    const elapsed_ns = timer.read();
    const elapsed_ms = timer.readMillis();

    // Direct clock reads, plus a backward-clock guard demo.
    const now_ns = ziotime.monotonicNanos(io);
    var guard: ziotime.MonotonicGuard = .{};
    _ = guard.observe(now_ns);
    const clamped = guard.observe(now_ns - 1_000); // a backward step is held flat

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        \\ziotime example
        \\  work took: {d} ns ({d} ms)
        \\  monotonicNanos: {d}
        \\  guard held backward step at: {d}
        \\
    , .{ elapsed_ns, elapsed_ms, now_ns, clamped });

    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, msg);
}
