# ziotime

## Overview

Monotonic clock helpers for Zig. Reads the monotonic clock, a minimal `Timer`,
and non-decreasing guards. Centralizes the churn from Zig 0.16 removing
`std.time.Timer` / `Instant` / `nanoTimestamp` (the monotonic clock moved behind
`std.Io.Clock.awake`). No internal wall clock; callers pass their own `io`.

## Project Structure

```
src/
  ziotime.zig    - Main library source (tests inline)
examples/
  example.zig    - Runnable example
build.zig        - Build configuration
```

## Commands

```bash
zig build test          # Run tests
zig build run-example   # Run the example
zig build               # Build the library
just ci                 # fmt-check + test + example (what CI runs)
```

## Architecture

Single-file library with no external dependencies. Compiles on BOTH Zig 0.15.2
and 0.16, selected by capability detection (`is_0_16 = @hasDecl(std.Io, "Clock")`),
mirroring zioshade's `compat.zig`. The untaken comptime branch is never analyzed,
so no version-only type leaks across builds.

## Testing

Tests are inline in `src/ziotime.zig`. Run with `zig build test`. Clock tests use
a helper (`runWithIo`) that constructs a short-lived `std.Io.Threaded` on 0.16 and
passes `void` on 0.15.2, so the same tests run on both toolchains.
