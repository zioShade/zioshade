## Rendering Comparison Results (2026-05-11)

### Method
- **glslpp pipeline**: GLSL → compileToSPIRV() → spirvToHLSL/GLSL/MSL()
- **Reference pipeline**: glslangValidator (-V -S frag) → SPIR-V → spirv-cross (--msl --msl-decoration-binding / --hlsl --shader-model 60 / --version 430)
- Both rendered on actual GPU hardware, compared per-pixel

### MSL Backend (macOS Metal, Apple M2, 256×256)

| Shader | glslpp bytes | spirv-cross bytes | Non-black (glslpp) | Non-black (ref) | Different pixels | Max diff | Result |
|--------|-------------|-------------------|---------------------|-----------------|------------------|----------|--------|
| CRT    | 6390        | 5256              | 61,481/65,536       | 61,481/65,536   | **0**            | 0        | ✅ MATCH |
| Focus  | 2803        | 3111              | 65,536/65,536       | 65,536/65,536   | **0**            | 0        | ✅ MATCH |

### GLSL Backend (Windows OpenGL 4.6, 128×128)

| Shader | glslpp bytes | spirv-cross bytes | Non-black (glslpp) | Non-black (ref) | Different pixels | Max diff | Result |
|--------|-------------|-------------------|---------------------|-----------------|------------------|----------|--------|
| CRT    | 5646        | 6886              | 15,376/16,384       | 15,376/16,384   | **0**            | 0        | ✅ MATCH |
| Focus  | 2267        | 2652              | 16,384/16,384       | 16,384/16,384   | **0**            | 0        | ✅ MATCH |

### HLSL Backend (Windows DXC validation, compiler-level)

| Shader | glslpp bytes | DXC result |
|--------|-------------|------------|
| CRT    | 6074        | ✅ Pass (ps_6_0) |
| Focus  | 2417        | ✅ Pass (ps_6_0) |

### Tools
- `tools/ShaderCompare.swift` — macOS Metal single-shader comparison
- `tools/ShaderBatchCompare.swift` — macOS Metal batch comparison
- `tools/gl_render_compare.c` — Windows OpenGL rendering comparison
- `tools/batch_compare.py` — Python batch orchestrator
