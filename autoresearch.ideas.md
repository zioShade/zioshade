# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 9/199 real output mismatches, 9/10 Ghostty shaders, 50/199 instruction-level matches
## Commit: 799acc2 (constant_composite upgrades)
## All 9 mismatches are vendor extensions NOT needed for wintty

## REMAINING 9 MISMATCHES (vendor extensions):
- QCOM image processing (4): block-match-sad/ssd, box-filter, sample-weighted
- ARM tensor (3): tensor, tensor_params, tensor_read
- nonuniform-qualifier (1): needs runtime arrays + nonuniformEXT + descriptor indexing
- ray-query (1): needs ray tracing

## DONE THIS SESSION:
- ✅ Skip identity VectorShuffle when swizzle selects all components in order
- ✅ Upgrade composite_construct → constant_composite for array/struct constructors with all-constant operands
- ✅ Cross-function constant ID lookup (check self.functions for constants from previous functions)
- ✅ Upgrade binary op scalar splats to constant_composite when operand is constant
- ✅ emitCompositeConstruct helper with automatic upgrade

## READY FOR WINTTY USE:
- ✅ 199/199 spirv-val conformance
- ✅ 9/10 Ghostty shaders (common.glsl is header-only)
- ✅ All standard GLSL shaders produce correct output stores
- ✅ ~150ms compilation time per shader
- ✅ 0 total_fail

## FUTURE OPTIMIZATION IDEAS:
- Reduce extra OpCompositeConstruct for 8-bit type constructors (need constant-folding through conversions)
- Runtime arrays (OpTypeRuntimeArray) for nonuniform-qualifier shader
- textureGather support
- GPU visual correctness verification (headless Vulkan renderer)
- Memory leak fix for tolerate_errors path (8 GPA leaks per complex shader)
- Performance optimization: avoid linear scan in isConstantId (use a set instead)
