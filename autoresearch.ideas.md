# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 543/566 total pass (209/302 spirv-cross + 334/356 glslang)
## 22 val_fail, 0 compile_fail, 1 crash (spv.floatFetch.frag)
## Session: 511→543 (+32 shaders, +6.3%)

## Dead Ends (investigated but not fixable)
- PhysSB Aligned: addPhysSBAligned pass crashes on bufferhandle24/25. Tracking loaded PhysSB pointers through pipeline fails because compactIds remaps all IDs.
- Extension preprocessor: Defining macros for unimplemented extensions causes regressions. Only GL_EXT_null_initializer is safe.

## Remaining Fixable (needs careful work)
- spv.bufferhandle5/24/25: compactIds ID collision + PhysSB Aligned
- 460.vert/spv.460.comp/spv.debuginfo.glsl.comp: Forward references from RSE pipeline
- bool_in_interface bvec (3): Double-free in codegen
- hoisted-temporary: Double-free in codegen

## Most Promising Next Steps

### 1. Missing image buffer type keywords (likely +3 shaders)
- uimageBuffer, iimageBuffer not in lexer → parsed as named types → OpTypeStruct instead of OpTypeImage
- Add keywords to lexer.zig, parser.zig, ast.zig
- Affected: spv.nonuniform4.frag, spv.imageAtomic64.frag, spv.descriptorHeap.AtomicImage.comp

### 2. web.operations.frag — DCE pipeline bug
- Compound assignments like iv3 -= iv3 produce load+compute+store
- Pipeline removes loads/stores but keeps arithmetic with self-referencing IDs
- Debug showed interleaved output from multiple shaders — need shader-specific debugging
- Complex fix, defer for later

### 3. Forward-reference pipeline bugs (3 shaders)
- 460.vert, spv.460.comp, spv.debuginfo.glsl.comp
- RSE cascade creates forward-referenced IDs after compactIds

