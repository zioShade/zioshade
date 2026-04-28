# Reference Compilation Failure Analysis

31 of 197 valid test shaders fail glslangValidator reference compilation.

## Category 1: Missing layout(binding=X) — 16 shaders
glslangValidator requires explicit binding on uniform buffers and samplers.
These shaders use GLSL 430+ implicit binding which our compiler supports.
- newTexture.frag, spv.newTexture.frag, spv.queryL.frag, spv.double.comp
- array.flatten.vert, basic.desktop.sso.vert, basic.flatten.vert, basic.vert
- copy.flatten.vert, dynamic.flatten.vert, inverse.legacy.vert
- matrixindex.flatten.vert, multiindex.flatten.vert, rowmajor.flatten.vert
- struct.flatten.vert, transpose.legacy.vert

## Category 2: Missing layout(location=X) — 4 shaders
glslangValidator requires explicit location on user I/O for SPIR-V.
- comment.frag, spv.430.frag, spv.AofA.frag, spv.qualifiers.vert

## Category 3: SPIR-V version requirements — 10 shaders
- 7 WorkgroupMemoryExplicitLayout shaders need SPIR-V 1.4
- 3 subgroup/quad shaders need SPIR-V 1.3

## Category 4: gl_VertexID deprecated — 1 shader
- full_screen.v.glsl uses gl_VertexID (replaced by gl_VertexIndex in Vulkan)

## Conclusion
None of these are bugs in glslpp. All 31 failures are due to:
- glslang strictness (layout bindings/locations)
- SPIR-V version mismatches (need --target-env flag)
- Deprecated Vulkan identifiers

