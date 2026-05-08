# Handoff: glslpp HLSL Backend Session

## Session Date: 2026-05-08

## What Was Done

### 1. License & Project Setup (L1) — COMPLETE
- Dual MIT/Apache-2.0 license with SPDX headers on all source files
- README with API docs, sponsor badge, build instructions
- `.github/FUNDING.yml`, `NOTICE`, `THIRD_PARTY_NOTICES.md`

### 2. SPIR-V → HLSL Backend (B1) — ~70% COMPLETE
Created `src/spirv_to_hlsl.zig` (~1100 lines) implementing:

**Working:**
- SPIR-V binary parser (header, all instruction types, ID→definition map)
- Type mapping: `vec`/`float`/`int`/`bool`/`mat` → HLSL equivalents
- Resource binding: UBO → `cbuffer` with `register(bN)`, binding remap `binding=1 → b0`
- Combined image-sampler handling: `TypeSampledImage` → `Texture2D` + `SamplerState` pair
- Correct texture sampling: `iChannel0.Sample(iChannel0_sampler, coord)`
- Constant inlining: scalars as literal values (`2.0`, `42`), vectors as constructors (`float2(0.5, 0.5)`)
- User function emission: non-entry functions emitted before `main`
- `OpFunctionCall` with argument passing
- 40+ GLSLstd450 → HLSL builtin mappings (sin/cos/pow/exp/log/min/max/clamp/lerp/dot/cross/etc.)
- All arithmetic, comparison, bitwise, conversion, composite operations
- Derivatives: `dFdx→ddx`, `dFdy→ddy`, `fwidth`
- Entry point semantics: `SV_Target`, `SV_Position`, `discard`

**Known gaps (next session):**
- Vector component writes via AccessChain use `._m0` instead of `.x`
- Full if/else block reconstruction from SelectionMerge+BranchConditional
- For loop reconstruction from LoopMerge+Branch
- Fragment output variable pattern (return `_fragColor` → proper return value)

### 3. Test Suite — 36 tests created (24 pass)
`tests/hlsl_tests.zig` with `zig build test-hlsl`:
- T1 minimal shaders (3/3), T7 constants (3/3), T8 derivatives (3/3) — all pass
- T9 shadertoy end-to-end (2/2), T14 semantics (3/3) — all pass
- T2-T5 type/binding/arithmetic/builtins: fail because DCE removes unused code in minimal shaders

### 4. Test Results on CRT Shadertoy Shader
- Input: wintty CRT shader with shadertoy prefix (68 lines GLSL)
- Output: 212 lines of HLSL with 0 unhandled operations
- Correct cbuffer binding, texture sampling, function calls, constant inlining

## Architecture

```
src/root.zig                  — Public API: compileToSPIRV, spirvToHLSL, compileShadertoyToHlsl
src/spirv_to_hlsl.zig         — SPIR-V parser + HLSL emitter (~1100 lines)
tests/hlsl_tests.zig          — 36 end-to-end HLSL tests
test_hlsl.zig                 — CLI tool for manual testing
test_crt_full.glsl            — Test shader (shadertoy prefix + CRT effect)
test_crt_full.glsl.hlsl       — Generated HLSL output (212 lines)
```

## How to Build & Test

```bash
ZIG=/path/to/zig-0.15.2/zig.exe

# Build library
$ZIG build

# Run HLSL backend tests (24/36 pass)
$ZIG build test-hlsl

# Run full conformance suite (spirv-val)
$ZIG build conformance

# Manual test on a specific shader
$ZIG build-exe -ODebug --dep glslpp -Mroot=test_hlsl.zig -Mglslpp=src/root.zig \
    --cache-dir .zig-cache -femit-bin=.zig-cache/bin/test_hlsl.exe
.zig-cache/bin/test_hlsl.exe test_crt_full.glsl --save
```

## Zig 0.15 ArrayList API Notes (learned the hard way)
- `ArrayList(T).init(alloc)` doesn't exist — use `initCapacity(alloc, n)` or `.empty`
- `.append(item)` takes alloc: `list.append(alloc, item)`
- `.deinit(alloc)` takes alloc
- `.toOwnedSlice(alloc)` takes alloc
- `.writer(alloc)` takes alloc
- AutoHashMap deinit doesn't take alloc

## Next Session Priorities (in order)

### P0: Fix the 3 DXC-blocking issues
1. **Vector component access**: AccessChain on vectors should emit `.x/.y/.z/.w` not `._m0`
   - In `emitInstruction` → `.AccessChain`: check if base type is a vector, use swizzle
   - Also fix stores: `v31._m0 = v46` should be invalid for float2

2. **Fragment output handling**: `_fragColor` should be the return value
   - The entry function should track stores to the output variable
   - Replace `return _fragColor;` with `return <last_stored_value>;`

3. **if/else control flow reconstruction**:
   - Pattern: `SelectionMerge(merge)` → `BranchConditional(cond, true, false)` → Label blocks → `Branch(merge)`
   - Need to build a basic block graph, then emit structured `if/else { }` blocks
   - Simple approach: scan forward from BranchConditional, collect true-block and false-block instructions until merge label

### P1: Loop reconstruction
- Pattern: `Branch → LoopHeader → LoopMerge(merge, continue) → BranchConditional → body → Branch(continue) → Branch(header)`
- Emit as `for (init; cond; update) { body }`

### P2: Fix failing tests
- T2-T6 tests fail because minimal shaders have DCE remove the interesting code
- Fix by using patterns that survive DCE, or by adding specific SPIR-V binary test data

### P3: DXC validation
- Install DXC, run `dxc -T ps_6_0 -E main` on generated HLSL
- Fix any DXC errors (undefined identifiers, type mismatches, etc.)

### P4: Performance comparison
- Benchmark: glslpp vs glslang+spirv-cross on wintty shaders
- Measure: wall-clock time, peak RSS, output size

## Key Files to Read First
1. `src/spirv_to_hlsl.zig` — the entire HLSL backend
2. `tests/hlsl_tests.zig` — test suite showing what works and what doesn't
3. `test_crt_full.glsl.hlsl` — actual output from CRT shadertoy shader
4. `PLAN.md` — full task list with progress tracking

## Git State
- Branch: `main`
- Latest commit: `a2676b8` — "Add HLSL backend test suite"
- 5 commits this session (license, HLSL backend, texture fix, std450 fallback, tests)
