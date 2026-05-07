# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 524/566 total pass (209/302 spirv-cross + 315/356 glslang)
## 41 val_fail, 0 compile_fail, 1 crash (spv.floatFetch.frag)

## Remaining Failure Categories:

### forward_ref / ID collisions (8 shaders)
- Root cause: codegen uses variable IDs where type IDs should be (e.g., OpTypeFunction return type = variable ID)
- Example: spv.1.4.OpEntryPoint.frag has `%31 = OpTypeFunction %3 %27` where %3 is `globalv` (Private var)
- Fix: investigate codegen's ID assignment for function types vs variables
- Affected: spv.1.4.OpEntryPoint.frag, spv.debuginfo.scalar_types.glsl.frag, spv.intrinsicsDebugBreak.frag, spv.intrinsicsSpirvDecorate.frag, spv.intrinsicsSpirvInstruction.vert, spv.tensorARM.size.comp, web.array.frag, spv.paramMemory.frag

### bool_in_interface (6 shaders)
- SPIR-V requires bool in Block-decorated structs to use uint
- At type registration: convert bool/bvecN members to uint/uvecN for UBO/SSBO structs
- At load: load as uint, convert to bool via OpINotEqual(x, 0)
- At store: convert bool to uint via OpSelect(cond, 1, 0), then store uint
- Affected: spv.boolInBlock.frag, spv.load.bool.array.interface.block.frag, etc.

### missing GLSL 460 features (3 shaders)
- 460.vert, spv.460.comp: anyInvocation, allInvocations, allInvocationsEqual (subgroup ballot)
- web.operations.frag: GLSL 460 operations
- spv.maximalReconvergence.vert, spv.subgroupUniformControlFlow.vert, spv.nullInit.comp: extensions not parsed

### constant_type (5 shaders)
- spv.1.4.OpSelect.frag: OpConstantComposite type mismatch
- spv.int16.amd.frag, spv.specConstant.int16/8.comp: 16/8-bit types not supported
- spv.structCopy.comp: OpSelect with struct from pointers (needs loads first)

### PhysicalStorageBuffer aligned (3 shaders)
- spv.bufferhandle5.frag, spv.bufferhandle24/25.frag: Missing Aligned memory operand
- Need to add Aligned operand to OpLoad/OpStore for PhysicalStorageBuffer pointers

### ConstOffset (3 shaders)
- spv.ext.textureShadowLod.frag, spv.specTexture.frag, spv.textureoffset_non_const.vert
- Image operand ConstOffset requires a constant object, we emit non-constant

### Image type issues (2 shaders)
- spv.nonuniform2/4.frag: Wrong image type in OpImageTexelPointer or similar

### Other (11 shaders)
- Various individual issues (debug info, decorations, extensions)

## BUGS FIXED THIS SESSION:

### RSE OpLabel opcode bug (248→1)
- redundantStoreElim was checking opcode 248 for OpLabel instead of 1
- This meant it never reset per-block tracking, treating stores in different branches as redundant
- Combined with elimRedundantLoads removing loads across branches, created dominance violations
- Fixed 3 shaders: spv.sampleId.frag, spv.samplePosition.frag, spv.shaderDrawParams.vert

### elimRedundantLoads cross-block dominance
- Only carry forward first_loads from entry block to subsequent blocks
- Non-entry blocks: clear first_loads to prevent cross-branch substitution

### inlineTrivialFuncs header bug
- Was copying words[0..4] + appending bound, resulting in schema=bound instead of schema=0
- Changed to words[0..5] to preserve schema

### Struct member type coercion
- When constructing a struct, convert each argument to match the member type (int→uint, etc.)
- Fixed OpConstantComposite type mismatch in spv.structCopy.comp

### final elimUnusedGlobals
- Added at end of pipeline to catch globals made unused by later optimization passes
- Didn't help the spv.1.4.OpEntryPoint.frag case (root cause is ID collision in codegen)
