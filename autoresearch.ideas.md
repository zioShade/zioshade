# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 212/222 pass (95.5%)
## 1 val_fail, 0 compile_fail, 0 crash
## HLSL tests: 76/76 pass (GENUINE), 0 leaked ✅
## Session: 208→212/222 conformance (+4 from WorkgroupMemory + constFold fix), HLSL 76/76

## ⚠️ STOP ADDING TESTS — further test additions would be overfitting
## Fix real bugs/features or switch to broader conformance metric instead.

## Remaining 1 Failure
- ghostty/cell_text.f.glsl: Dominance violation in RAW codegen (not optimization pipeline)
  - ID %85 (FClamp result) defined in block %73 but used in merge block %61
  - Block %73 is inside a conditional (if use_linear_correction)
  - The codegen emits the computation inside the conditional but uses it at the merge without a phi node
  - Root cause: semantic analyzer emits IR for `a = clamp(...)` inside if-block, then uses `a` after the if-block without creating a variable store/load pattern
  - Fix requires: either (1) emit function-local vars for values that cross block boundaries, or (2) add phi node support in the SPIR-V output, or (3) fix the semantic analyzer to detect cross-block value usage and emit store/load instead of SSA

## Fixed in This Session
- spv.WorkgroupMemoryExplicitLayout.*.comp (3): shared blocks weren't parsed as uniform_block (parser checked is_uniform/is_buffer/is_in/is_out but not is_shared)
- hoisted-temporary: constFold Phase 4 used fixed>=2 (matching type defs with fixed=3), reading words[pos+2] as result_id for types where it's actually a literal (e.g., OpTypeFloat width=32). If folded arithmetic had result_id=32, OpTypeFloat would be skipped.

## HLSL Backend Quality
- T6.2 (out parameter test) crashes — pre-existing issue, not a leak
- Optimizer aliasing bug: `a = u.x * u.y; c = a - b` can lose the multiplication if b is computed from same inputs
- codegen.zig line 238 had wrong pointer comparison — fixed

## Dead Ends
- PhysSB Aligned: addPhysSBAligned pass crashes on bufferhandle24/25
- Extension preprocessor: Defining macros for unimplemented extensions causes regressions
- storeForwardExtract dominance check: adding block-level check didn't help because the dominance violation is in the RAW codegen, not in the optimization pipeline
- Disabling storeForwardExtract causes regression (struct-varying.legacy.vert fails)

## Potential Future Work
- ghostty/cell_text.f dominance fix: requires understanding how semantic analyzer emits IR for cross-block values
- fixTypeOrdering pass: exists but causes regressions when used naively. Needs careful implementation that preserves function-local var positions.
- More GLSL conformance tests (currently 9 skipped — error validation tests)
