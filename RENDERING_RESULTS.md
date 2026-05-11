## Rendering Comparison Results (2026-05-11)

### CRT Shader (barrel distortion, chromatic aberration, scanlines)
- Resolution: 256×256 (65,536 pixels)
- glslpp MSL: 6390 bytes, spirv-cross MSL: 5256 bytes
- **Different pixels: 0 (pixel-perfect match)**
- Max channel diff: 0, Avg: 0.0000

### Focus Shader (focus mode with edge detection)
- Resolution: 256×256 (65,536 pixels)
- glslpp MSL: 2803 bytes, spirv-cross MSL: 3111 bytes
- **Different pixels: 0 (pixel-perfect match)**
- Max channel diff: 0, Avg: 0.0000

### Method
- Generated glslpp MSL via: glslpp compileToSPIRV → spirvToMSL
- Generated reference MSL via: glslangValidator -V → spirv-cross --msl --msl-decoration-binding
- Both rendered on Apple M2 via Metal, compared per-pixel
