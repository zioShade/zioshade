# Autoresearch: Replace glslang C++ with Pure Zig in deblasis/wintty

## Phased Approach

### Phase 1: Reduce Store Mismatches (CURRENT)
**Metric**: `store_mismatches` (lower is better) — count of shaders where our OpStore count differs from glslang's.
**Baseline**: 95/199 mismatches (104/199 match = 52.3%)
**Constraint**: 199/199 spirv-val conformance must be maintained.

**Breakdown of 95 mismatches:**
- 41 "missing feature" (we emit 0 stores — shader features we don't implement)
- 31 "minor diff" (1-3 stores off — small logic differences)
- 23 "major diff" (>3 stores off — significant logic differences)

**Categories of missing features (41 shaders):**
- fp64/double support: fp64.desktop.comp (42 stores)
- int64 support: int64.desktop.comp (12 stores)
- image query functions: image-query.desktop.frag (28 stores)
- tensor/cooperative vector: tensor_*.comp, cooperative-vec-nv (27+ stores)
- spec constants: spec-constant-*.comp/frag (6 stores)
- input attachments: input-attachment*.frag (2 stores)
- subgroup operations: shader_ballot, shader_group_vote, shared (18 stores)
- separate sampler/texture: separate-sampler-texture*.frag (22 stores)
- nonuniformEXT: nonuniform-qualifier (18 stores)
- extended arithmetic: extended-arithmetic (32 stores)
- demote-to-helper, shader-clock, struct-type-alias, etc.

**Categories of minor/major diffs (54 shaders):**
- modf/frexp output: multi-component swizzle writes needed
- struct flattening: in/out block member handling
- row-major array access: read-from-row-major-array.vert
- composite construction patterns
- for-loop/switch logic differences
- function inlining vs separate definitions

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
