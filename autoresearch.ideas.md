# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 538/566 total pass (209/302 spirv-cross + 329/356 glslang)
## 27 val_fail, 0 compile_fail, 1 crash (spv.floatFetch.frag)
## Session: 511→538 (+27 shaders, +5.3%)

## Remaining Failures (28):

### Deep codegen/semantic bugs (require careful debugging)
- spv.boolInBlock.frag: semantic analyzer silently fails with tolerate_errors, produces empty function body for bvec4 in uniform block
- spv.bufferhandle5/24/25.frag: compactIds ID collision (load source pointer gets same ID as OpTypeFunction)
- hoisted-temporary-use-continue-block-as-value.frag: double-free in codegen
- web.operations.frag: compound assignment result_id==operand_id
- 460.vert, spv.460.comp: RSE pipeline forward references
- spv.debuginfo.glsl.comp: forward references from optimization pipeline

### bool_in_interface (3) — bvec/array cases
- spv.boolInBlock.frag: (also counted above - semantic analyzer fails)
- spv.load.bool.array.interface.block.frag: double-free crash
- spv.1.4.load.bool.array.interface.block.frag: double-free crash

### GLSL extensions/parsing (5) — NOT FEASIBLE without parser work
- spv.intrinsicsDebugBreak/SpirvDecorate/SpirvInstruction: spirv_intrinsics ext
- spv.maximalReconvergence/subgroupUniformControlFlow: GL_EXT extensions
- spv.nullInit.comp: GL_EXT_null_initializer

### PhysicalStorageBuffer (3)
- spv.bufferhandle5/24/25.frag: Missing Aligned memory operand + compactIds collision

### 16-bit types (3) — NOT FEASIBLE without type system work
- spv.16bitxfb.vert, spv.int16.amd.frag, spv.specConstant.int16/8.comp

### Other individual issues (7)
- spv.bufferhandle22.frag: buffer_reference forward reference
- spv.nontemporalbuffer.frag: nontemporal keyword not supported
- spv.imageAtomic64.frag: OpImageTexelPointer type mismatch
- spv.nonuniform4.frag: OpImageTexelPointer type mismatch
- spv.tpipTextureArrays.frag: QCOM extension
- spv.descriptorHeap.AtomicImage.comp: ImageTexelPointer int vs uint
- spv.floatFetch.frag: segfault in optimization pipeline

### Key insights from investigation
- copyMemoryOpt uses opcode 63 (OpCopyLogical) instead of 46 (OpCopyMemory) — fixing alone doesn't help due to compactIds collision
- The bool_in_interface bvec cases require the semantic analyzer to handle bvec types in uniform/storage blocks (currently fails silently with tolerate_errors)
- Most remaining failures are either: missing GLSL extensions (5), deep bugs needing careful debugging (6+), or type system work (3)
