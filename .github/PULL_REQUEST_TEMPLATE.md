## What

Brief description of the change.

## Why

What problem this solves or what capability it adds. Link to an issue if applicable.

## Tests

- [ ] `zig build test` passes
- [ ] `zig build test-hlsl` passes (if HLSL backend changed)
- [ ] `zig build conformance` — <!-- STATUS:conformance.summary -->2,080 PASS / 7 FAIL / 8 SKIP / 2,095 TOTAL<!-- /STATUS --> does not regress (PASS must not drop, FAIL must not grow; `just status` verifies)
- [ ] For SPIR-V emitter / cross-compiler changes: `zig build fuzz -- --count 5000` is clean
- [ ] New regression fixtures added under `tests/conformance/stress/` if a new shader feature is supported

## Notes for the reviewer

Anything worth calling out — known limitations, follow-ups, perf considerations.
