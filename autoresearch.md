# Autoresearch: Maximize GLSL-to-SPIR-V Conformance

## Objective
Maximize the number of shaders that pass through the full pipeline (lexer → preprocessor → parser → semantic → codegen) and validate with spirv-val. The compiler is glslpp, a GLSL-to-SPIR-V compiler in Zig (~6500 LOC). Currently only 1 shader passes (minimal_test.frag). Goal: maximize pass count across all 3 test suites.

## Metrics
- **Primary**: total_pass (unitless, higher is better) — total shaders passing spirv-val
- **Secondary**: total_compile_error, total_fail (spirv-val), total_skip, total_hang — independent monitors

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

The script compiles the runner, then runs each test suite with per-file timeouts to avoid hangs. Reports structured metrics.

## Files in Scope
- `src/parser.zig` (~1340 lines): Pratt parser. Main source of hangs on unexpected constructs.
- `src/semantic.zig` (~1377 lines): Symbol resolution, type checking, IR emission.
- `src/codegen.zig` (~898 lines): IR → SPIR-V binary emission.
- `src/preprocessor.zig` (~1228 lines): #define, #ifdef, macro expansion. Missing #include.
- `src/lexer.zig` (~900 lines): Tokenizer.
- `src/ast.zig` (~217 lines): AST node definitions, type system.
- `src/ir.zig` (~144 lines): IR instruction tags and Module/Function/Global definitions.
- `src/spirv.zig` (~251 lines): SPIR-V opcodes, capabilities, decorations.
- `tests/runner.zig` (~160 lines): Conformance test runner.
- `build.zig` (~165 lines): Build configuration.

## Off Limits
- `src/root.zig` public API (`compileToSPIRV` signature) — don't break callers
- Don't run `zig build test` — causes OOM (>2GB RAM per instance)
- Don't modify the test shader files in tests/

## Constraints
- All changes must compile with Zig 0.15.2
- No new external dependencies
- Must not introduce regressions on already-passing shaders
- Must handle hangs gracefully (per-file timeouts)

## What's Been Tried

### Baseline (commit 9088390)
True baseline: **2 pass / 101 compile_error / 15 spirv-val fail / 79 hang / 0 crash** out of 197 valid test files.
Used glslangValidator to classify: 197 valid, 136 invalid, 20 skipped out of 353 total.

Key discoveries:
- PASS detection was broken (summary "PASS: 0" line matched grep → ~214 false positives)
- struct-varying.legacy.frag appears as PASS but has double-free memory corruption (GPA prints error but exits 0)
- Ghostty .glsl files need -S frag/vert for glslangValidator
- common.glsl is include-only, not standalone

### Architecture Notes
- Pipeline: source → lexer.tokenize() → parser.parse() → semantic.analyze() → codegen.generate() → SPIR-V words
- The runner.zig calls `glslpp.compileToSPIRV()` and then writes the result to a temp file and runs spirv-val
- Stage detection is NOT in runner.zig — it always uses `.fragment` stage. This is wrong for .vert and .comp files.
- Many hangs likely caused by parser infinite loops on unrecognized constructs
- The `synchronize()` method in parser tries to recover from errors by skipping to semicolons/r-brace/type keywords

### Key Bugs to Fix (Priority Order)
1. **Parser hangs**: FIXED — synchronize() now consumes r_brace.
2. **OpEntryPoint interface variables**: FIXED — Input/Output globals listed as operands.
3. **Double-free in struct members**: FIXED — TypeDef duplicates members slice.
4. **GL builtins not emitted as globals**: FIXED — gl_Position etc now registered as proper globals.
5. **Compile errors (132 files)**: Missing language features + type promotion gaps.
6. **spirv-val failures (43 files)**: Wrong SPIR-V output — type mismatches, undefined IDs.
7. **#include preprocessor**: Needed for Ghostty shaders (10 files).
8. **Uniform blocks**: Basic support added, member access chains need storage class fix.
9. **Switch statements**: No parser support yet.
