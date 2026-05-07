# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 534/566 total pass (209/302 spirv-cross + 325/356 glslang)
## 31 val_fail, 0 compile_fail, 1 crash (spv.floatFetch.frag)

## Remaining Failure Categories (31):

### bool_in_interface (6 shaders) — HIGHEST IMPACT
- SPIR-V requires bool in Block-decorated structs to use uint
- At type registration: convert bool/bvecN members to uint/uvecN for UBO/SSBO structs
- At load: load as uint, convert to bool via OpINotEqual(x, 0)
- At store: convert bool to uint via OpSelect(cond, 1, 0), then store uint
- Affected: spv.boolInBlock.frag, spv.load.bool.array.interface.block.frag, 
  spv.1.4.load.bool.array.interface.block.frag, spv.multiStruct.comp,
  spv.shaderGroupVote.comp, spv.1.4.OpCopyLogicalBool.comp

### GLSL 460 features (3 shaders)
- 460.vert, spv.460.comp: anyInvocation, allInvocations, allInvocationsEqual
- web.operations.frag: GLSL 460 operations

### GLSL extensions not parsed (5 shaders)
- spv.intrinsicsDebugBreak.frag: spirv_instruction extension
- spv.intrinsicsSpirvDecorate.frag: spirv_decorate extension
- spv.intrinsicsSpirvInstruction.vert: spirv_instruction extension
- spv.maximalReconvergence.vert, spv.subgroupUniformControlFlow.vert: GL_EXT extensions
- spv.nullInit.comp: GL_EXT_null_initializer

### PhysicalStorageBuffer aligned (3 shaders)
- spv.bufferhandle5.frag, spv.bufferhandle24/25.frag: Missing Aligned memory operand

### 16-bit types (3 shaders)
- spv.16bitxfb.vert, spv.int16.amd.frag, spv.specConstant.int16/8.comp

### OpSelect with struct pointers (1 shader)
- spv.structCopy.comp: OpSelect with AccessChain pointers instead of loaded values

### Other (7 shaders)
- hoisted-temporary-use-continue-block-as-value.frag: Type Id is not a type (codegen bug)
- spv.bufferhandle22.frag: forward ref (buffer_reference extension)
- spv.nontemporalbuffer.frag: AtomicIAdd with Private storage
- spv.imageAtomic64.frag: Wrong image type
- spv.nonuniform4.frag: Wrong image type
- spv.tpipTextureArrays.frag: Missing decoration
- spv.debuginfo.glsl.comp: forward ref (debug info extension)

## NEXT TARGETS (by effort/impact):
1. bool_in_interface (6 shaders, MEDIUM effort)
2. GLSL 460 features (3 shaders, MEDIUM effort)
3. OpSelect struct fix (1 shader, LOW effort)
4. PhysicalStorageBuffer aligned (3 shaders, MEDIUM effort)
