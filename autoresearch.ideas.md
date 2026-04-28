# Autoresearch Ideas

## CURRENT STATUS: 197/197 spirv-val, 9/10 Ghostty shaders pass

## GOAL: Replace glslang C++ pipeline in deblasis/wintty with pure Zig implementation

### DONE this session:
- ✅ Function overload resolution: return_type stored in OverloadEntry (linearize bug)
- ✅ Bool-to-float/int/uint: OpSelect-based conversion for type constructors
- ✅ Int vector → float vector conversion in binary ops and compound assignments
- ✅ pack/unpack builtin detection: exact name matching instead of prefix
- ✅ Ghostty shaders: 1/10 → 9/10 (only common.glsl fails — include-only file)

### NEXT: Layout decorations (critical for GPU correctness)
TIER 1 - Required for correct UBO/SSBO memory layout:
- Offset member decorations for UBO/SSBO struct members (std140/std430 layout rules)
- Block/BufferBlock decorations on uniform/storage buffer struct types
- ArrayStride decorations on array types in buffers
- ColMajor/RowMajor + MatrixStride for matrix members

TIER 2 - Important for feature parity:
- DescriptorSet decorations on samplers/images
- NonReadable/NonWritable on images/SSBOs
- OpExecutionMode LocalSize for compute shaders
- OpSource directive
- Flat/Centroid/Component on IO variables

### Equivalency metrics (166 both-valid shaders):
| Metric     | Ours  | Ref   | Ratio |
|------------|-------|-------|-------|
| ID Bound   | 7,446 | 10,159| 0.73x |
| Total lines| 9,554 | 17,381| 0.55x |
| Functions  | 235   | 225   | 1.04x |
| Types      | 1,951 | 2,616 | 0.75x |
| Constants  | 567   | 1,103 | 0.51x |
| Variables  | 640   | 1,010 | 0.63x |
