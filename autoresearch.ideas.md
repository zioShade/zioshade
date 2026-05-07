# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 535/566 total pass (209/302 spirv-cross + 326/356 glslang)
## 30 val_fail, 0 compile_fail, 1 crash (spv.floatFetch.frag)
## Session: 511→535 (+24 shaders, +4.7%)

## Remaining Failures (30):

### bool_in_interface (6) — HIGHEST IMPACT
- SPIR-V requires bool in Block structs to use uint
- Affected: spv.boolInBlock.frag, spv.load.bool.array.interface.block.frag, 
  spv.1.4.load.bool.array.interface.block.frag, spv.multiStruct.comp,
  spv.shaderGroupVote.comp, spv.1.4.OpCopyLogicalBool.comp
- Fix: convert bool→uint in UBO/SSBO struct emission, add load/store conversions

### GLSL extensions/parsing (5) — NOT FEASIBLE without parser work
- spv.intrinsicsDebugBreak/SpirvDecorate/SpirvInstruction: spirv_intrinsics ext
- spv.maximalReconvergence/subgroupUniformControlFlow: GL_EXT extensions
- spv.nullInit.comp: GL_EXT_null_initializer

### PhysicalStorageBuffer aligned (3)
- spv.bufferhandle5/24/25.frag: Missing Aligned memory operand

### 16-bit types (3) — NOT FEASIBLE without type system work
- spv.16bitxfb.vert, spv.int16.amd.frag, spv.specConstant.int16/8.comp

### GLSL 460 features (2) — codegen issues
- 460.vert, spv.460.comp: subgroup ballot ops (anyInvocation etc)
- web.operations.frag: GLSL 460 ops

### Optimization pipeline bugs (2)
- spv.460.comp: forward reference from RSE + compactIds cascade
- hoisted-temporary-use-continue-block-as-value.frag: Type Id not a type

### Other individual issues (9)
- spv.bufferhandle22.frag: buffer_reference extension
- spv.nontemporalbuffer.frag: AtomicIAdd with Private
- spv.imageAtomic64.frag, spv.nonuniform4.frag: image type issues
- spv.tpipTextureArrays.frag: QCOM extension
- spv.debuginfo.glsl.comp: debug info extension
- spv.descriptorHeap.AtomicImage.comp: image capability
- spv.structCopy.comp: already fixed (ternary auto-load)
- spv.1.4.OpCopyLogicalBool.comp: bool in interface (counted above)
