# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders, 49/199 instruction-level matches
## Commit: d7e7fc9 (skip identity VectorShuffle)

## REMAINING 9 MISMATCHES (all vendor extensions — not needed for wintty):
- QCOM image processing (4): block-match-sad/ssd, box-filter, sample-weighted
- ARM tensor (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1): needs runtime arrays + nonuniformEXT + descriptor indexing
- ray-query (1): needs ray tracing

## DONE THIS SESSION:
- ✅ Skip identity VectorShuffle when swizzle selects all components in order

## TRIED & REVERTED:
- Adding i16vec/u16vec/f16vec to isTypeKeyword → spv.nvAtomicFp16Vec.frag regression
- OpControlBarrier=227 (WRONG — it's OpAtomicLoad!) → Fixed to 224

## CODE QUALITY OBSERVATIONS:
- 102 shaders have fewer OpAccessChain (349 vs 1012) — our SSA approach uses fewer pointers
- 27 shaders have more OpCompositeConstruct (102 vs 70) — extra splats
- 13 shaders have more OpVectorShuffle (95 vs 52) — partial swizzle extracts
- 6 shaders have more OpFMul (72 vs 27) — not using VectorTimesScalar everywhere

## FUTURE OPTIMIZATION IDEAS:
- Extend VectorTimesScalar: detect more float vec×scalar patterns to reduce OpFMul count
- Reduce extra OpCompositeConstruct for non-literal args (27 shaders have extras)
- Runtime arrays (OpTypeRuntimeArray) for nonuniform-qualifier shader
- textureGather support
- GPU visual correctness verification
- Memory leak fix for tolerate_errors path
