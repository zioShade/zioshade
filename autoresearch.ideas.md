# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance (spirv-valid), but Ghostty shaders have function overload resolution bugs

## GOAL: Replace glslang C++ pipeline in deblasis/wintty with pure Zig implementation

### BLOCKER #1: Function overload resolution (all 7 Ghostty shader failures)
- `linearize(float)` and `linearize(vec4)` both exist in common.glsl
- When calling `linearize(float_val)`, compiler picks the vec4 overload instead
- Fix: implement proper overload resolution based on parameter types
- This is the single most important fix for the wintty use case

### BLOCKER #2: Missing layout decorations (TIER 1 for GPU correctness)
- Offset member decorations for UBO/SSBO structs
- Block/BufferBlock decorations on struct types
- ArrayStride decorations on array types
- ColMajor/RowMajor/MatrixStride for matrix members
- These don't cause spirv-val failures but WILL cause incorrect GPU behavior

### BLOCKER #3: Missing DescriptorSet on samplers/images
- Ghostty shaders use `layout(binding=0)` but may need DescriptorSet too

### Other equivalency gaps (TIER 2-3):
- NonReadable/NonWritable on images/SSBOs
- OpExecutionMode LocalSize for compute shaders
- Flat/Centroid/Component on IO
- RelaxedPrecision for mediump
- OpSource directive
- OpName/OpMemberName for debug info
