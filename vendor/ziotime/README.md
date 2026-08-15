# ziotime

Monotonic clock helpers for Zig. Read the monotonic clock, time intervals with a
minimal `Timer`, and clamp backward clock steps.

## The pitch

Zig 0.16 removed `std.time.Timer`, `std.time.Instant` and
`std.time.nanoTimestamp`. The monotonic clock moved behind `std.Io` and is now
read as `std.Io.Clock.awake.now(io)`. Every consumer that timed an interval must
be rewritten and must thread an `Io` through. ziotime does that once so the whole
fleet upgrades in one place.

```zig
const ziotime = @import("ziotime");

// Time a chunk of work. `io` is your std.Io (void on Zig 0.15.2).
var timer = ziotime.Timer.start(io);
doWork();
const elapsed_ns = timer.read();       // nanoseconds since start
const elapsed_ms = timer.readMillis(); // milliseconds since start

// Read the clock directly.
const now_ns = ziotime.monotonicNanos(io);
const now_ms = ziotime.monotonicMillis(io);

// Never let a subtraction underflow on a backward step.
const dt = ziotime.elapsedSince(earlier_ns, now_ns); // 0 if it went backward

// Ratchet an externally-supplied timestamp stream so it never decreases.
var guard: ziotime.MonotonicGuard = .{};
const clamped = guard.observe(external_now_ns);
```

## Install

```bash
zig fetch --save git+https://github.com/deblasis/ziotime
```

Then in your `build.zig`:

```zig
const dep = b.dependency("ziotime", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("ziotime", dep.module("ziotime"));
```

## API

- `monotonicNanos(io)` - monotonic clock in nanoseconds (non-decreasing)
- `monotonicMillis(io)` - monotonic clock in milliseconds
- `Timer.start(io)` / `.read()` / `.readMillis()` / `.reset()` / `.lap()` - elapsed timer
- `elapsedSince(earlier_ns, later_ns)` - saturating interval (0 on backward step)
- `MonotonicGuard` / `.observe(now_ns)` - ratchet a timestamp stream non-decreasing
- `Io` - the I/O context alias (`std.Io` on 0.16, `void` on 0.15.2)
- `ns_per_ms`, `ns_per_s` - unit constants

`io` is whatever `std.Io` you already thread through your program (e.g. from a
`std.Io.Threaded`). Nothing is hidden behind a process-global clock; `Timer`
captures the `io` you pass to `start` and reuses it.

## Compatibility

- **Zig**: 0.16.0 (primary) and 0.15.2, selected by capability detection
  (`@hasDecl(std.Io, "Clock")`) rather than a version number, mirroring the
  proven dual-version pattern in zioshade's `compat.zig`. The untaken comptime
  branch is never analyzed, so no version-only type leaks across builds.
- **Platforms**: Linux, macOS, Windows (whatever the active `std.Io` supports).
- **Breaking changes**: follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
  Minor versions add features, patch versions fix bugs.

## License

Dual-licensed under either of

- [MIT License](LICENSE-MIT)
- [Apache License 2.0](LICENSE-APACHE)

at your option. Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion shall be dual-licensed as above without additional terms.
