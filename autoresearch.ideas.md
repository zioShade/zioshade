# Autoresearch Ideas

## CURRENT STATUS: 197/197 conformance, SPIR-V output ~glslang parity (0.99x)

### Metrics progress:
| Iteration | our_bound | ref_bound | overhead | our_vars | ref_vars |
|-----------|-----------|-----------|----------|----------|----------|
| Baseline  | 29142     | 10159     | 2.87x    | 6782     | 1010     |
| ID waste fix | 10015 | 10159     | 0.99x ✅ | 879      | 1010     |
| Image query fix | 10044 | 10159 | 0.99x    | 884      | 1010     |

### Key insight: bound BELOW glslang means missing functionality
- our_vars=884 vs ref_vars=1010: We're creating fewer variables than glslang
- image-query.desktop.frag: We generate 6/28 OpImageQuery ops
- Missing sampler types (sampler_cube_array as non-shadow), missing image types (image1D, image3D, imageCube)
- Parser maps image3D/imageCube/image2DArray → image2d (fallback)

### Opportunities for functional completeness:
1. **Add missing image types**: image1D, image3D, imageCube, imageCubeArray, image2DArray
   to ast.zig, lexer.zig, parser.zig — needed for image-query.desktop.frag
2. **Add sampler_cube_array (non-shadow)**: ast.zig type + lexer + parser + codegen
3. **More complete extract_image in codegen**: isampler/isampler_cube/isampler_cube_array
   extract_image needs int-type inner IDs for cube variants
4. **imageSize support for all image types**: Needs the image types to exist first

### Optimization (minor, diminishing returns):
5. **Per-shader bound reduction**: Some shaders still 1.04x glslang (1 extra ID)
6. **OpVariable count**: 884 vs 1010 — some shaders may need more variables for correctness
