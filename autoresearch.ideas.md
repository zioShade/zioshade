# Autoresearch Ideas

## CURRENT STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders, 49/199 instruction-level matches

## DONE THIS SESSION:
- ✅ OpControlBarrier opcode fix (227→224)
- ✅ barrier()/memoryBarrier*() SPIR-V instructions
- ✅ Skip float-to-vector splat for mul_assign → VectorTimesScalar
- ✅ Skip splat for swizzle compound multiply → VectorTimesScalar
- ✅ Float vector OpConstantComposite for all-literal constructors (42→49 matches)

## REMAINING 9 MISMATCHES (all vendor extensions — not needed for wintty):
- block-match-sad.spv14.frag — QCOM image processing (out=0/2)
- block-match-ssd.spv14.frag — QCOM image processing (out=0/2)
- box-filter.spv14.frag — QCOM image processing (out=0/2)
- sample-weighted.spv14.frag — QCOM image processing (out=0/2)
- nonuniform-qualifier.vk.nocompat.frag — needs runtime arrays + nonuniformEXT + descriptor indexing
- rq-position-fetch.vk.spv14.nocompat.frag — needs ray tracing
- tensor.nocompat.noopt.vk.frag — ARM tensor operations (out=0/1)
- tensor_params.nocompat.invalid.vk.comp — ARM tensor (buf=0/1)
- tensor_read.nocompat.noopt.vk.comp — ARM tensor (buf=0/1)

## TRIED & REVERTED:
- Adding i16vec/u16vec/f16vec to isTypeKeyword → spv.nvAtomicFp16Vec.frag regression
- OpControlBarrier=227 (WRONG — it's OpAtomicLoad!) → Fixed to 224

## FUTURE OPTIMIZATION IDEAS:
- Reduce extra OpCompositeConstruct for non-literal args (65 shaders still have extras)
- Extend constant_composite to handle `vec4(int_val)` when int_val resolves to constant
- Runtime arrays (OpTypeRuntimeArray) for nonuniform-qualifier
- textureGather support
- GPU visual correctness verification
- Memory leak fix for tolerate_errors path
