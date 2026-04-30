# Autoresearch: Replace glslang C++ with Pure Zig in deblasis/wintty

## Phased Approach

### Phase 1: Reduce Output Store Mismatches (CURRENT)
**Metric**: `output_store_mismatches` (lower is better) — count of shaders where our OpStore count to Output/StorageBuffer variables differs from glslang's.
**Baseline**: 40/199 mismatches (159/199 match = 79.9%)
**Constraint**: 199/199 spirv-val conformance must be maintained.

**Breakdown of 22 real mismatches:**
- 14 shaders: we emit 0 output stores (out=0/ref=N) — missing features
- 8 shaders: different output store counts (logic differences like swizzle writes, struct flattening)

**Plus 18 false positives** (gl_PerVertex block wrapping — we use gl_Position directly, glslang wraps in gl_PerVertex. Structurally different but functionally equivalent.)

### Phase 2: Normalized Instruction Comparison
**Metric**: `struct_match_rate` — percentage of shaders where normalized SPIR-V instruction sequence matches glslang.
**Tool**: Normalize disassembly (strip IDs, debug info), compare instruction-by-instruction.

### Phase 3: GPU Visual Correctness (FUTURE)
**Metric**: `pixel_diff` — percentage of pixels that differ when rendering with our SPIR-V vs glslang's.
**Setup needed**: Headless Vulkan renderer that:
1. Renders a fullscreen triangle with known uniforms/textures
2. Captures framebuffer for both SPIR-V binaries
3. Computes per-pixel diff
4. Reports match percentage

### Phase 4: Performance Optimization (AFTER 100% correctness)
**Metric**: `compile_time_us` or `total_bound` (SPIR-V output size)
**Constraint**: Zero correctness regression (store_mismatches must not increase).

## How to Run
`bash autoresearch.sh` — outputs METRIC lines.

## Files in Scope
- `src/parser.zig`: Pratt parser
- `src/semantic.zig`: Symbol resolution, type checking, IR emission
- `src/codegen.zig`: IR → SPIR-V binary emission
- `src/preprocessor.zig`: #define, #ifdef, macro expansion
- `src/lexer.zig`: Tokenizer
- `src/ast.zig`: AST node definitions, type system
- `src/ir.zig`: IR instruction tags and Module/Function/Global definitions
- `src/spirv.zig`: SPIR-V opcodes, capabilities, decorations

## Off Limits
- `src/root.zig` public API (`compileToSPIRV` signature) — don't break callers
- Don't run `zig build test` — causes OOM
- Don't modify the test shader files in tests/

## Constraints
- All changes must compile with Zig 0.15.2
- Must not introduce regressions on already-passing shaders
- Must maintain 199/199 spirv-val conformance

## Build
```bash
ZIG=/c/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe
$ZIG build-exe -OReleaseSafe --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe
```
