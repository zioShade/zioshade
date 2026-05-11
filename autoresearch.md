# Autoresearch: glslpp correctness and performance

## Objective
Make glslpp's SPIR-V cross-compilation backends (HLSL, GLSL, MSL) 100% correct
for all shaders in the reference test suite, then optimize for performance.

## Metrics
- **Primary**: `test_failures` (unitless, lower is better) — count of failing reference tests
- **Secondary**: `build_ms` — time to run full test suite (milliseconds)

## How to Run
`mise exec -- bash autoresearch.sh` — outputs `METRIC` lines.

## Files in Scope
- `src/spirv_to_hlsl.zig` — HLSL backend (2077 lines)
- `src/spirv_to_glsl.zig` — GLSL backend (self-contained parser + emitter)
- `src/spirv_to_glsl_emit.zig` — GLSL emit functions
- `src/spirv_to_msl.zig` — MSL backend (self-contained parser + emitter)
- `src/spirv_cross_common.zig` — shared parser/helpers
- `src/spirv.zig` — SPIR-V enum definitions
- `tests/reference_tests.zig` — the correctness test suite (76 tests)

## Off Limits
- `src/root.zig` public API (don't change signatures)
- `src/codegen.zig` (frontend compiler — not our target)
- `src/semantic.zig` (frontend — not our target)
- `build.zig` (build config — stable)

## Constraints
- All existing tests must continue passing: core (76), HLSL (751), GLSL (91), MSL (39)
- No memory leaks
- No new dependencies
- Keep code simple and readable — prefer clear patterns over cleverness

## Known Issues (as of commit d21b5df)
10 reference tests fail due to missing opcodes:
- **Op 63 (CopyMemory)** — GLSL backend, used for struct copies in swizzle/front-facing
- **Op 100 (OpImage)** — GLSL backend, extracts image from sampled_image for texelFetch
- **Op 194 (ShiftRightLogical)** — GLSL backend
- **Op 196 (ShiftLeftLogical)** — GLSL backend  
- **std450 #33 (Determinant)** — MSL backend (MSL std450ToMsl needs #33 => "determinant")
- **Various file tests** fail due to above opcodes + potentially more

## Architecture Notes
- GLSL and MSL backends are self-contained (own parser, own emitter) — not shared
- HLSL backend uses spirv_cross_common.zig for parsing
- All backends follow the same pattern: parse SPIR-V → collect names/decorations → emit target language
- The `resultIdFromOp` function in each backend defines which opcodes produce named results
- The `emitInstruction` switch handles opcode emission — add missing cases there
- std450 function mapping uses numeric IDs matching the SPIR-V GLSLstd450 enum (see spirv.zig)

## What's Been Tried
(autoresearch will fill this in)
