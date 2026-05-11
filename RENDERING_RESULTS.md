## Rendering Comparison Results (2026-05-11)

### Method
- **glslpp pipeline**: GLSL → compileToSPIRV() → spirvToHLSL/GLSL/MSL()
- **Reference pipeline**: Original GLSL compiled and rendered directly (OpenGL) OR glslangValidator (-V) → SPIR-V → spirv-cross (--version 430) for cross-compilation comparison
- Both rendered on actual GPU hardware, compared per-pixel

### MSL Backend (macOS Metal, Apple M2, 256×256)

| Shader | glslpp bytes | spirv-cross bytes | Different pixels | Result |
|--------|-------------|-------------------|------------------|--------|
| CRT    | 6390        | 5256              | **0/65,536**     | ✅ MATCH |
| Focus  | 2803        | 3111              | **0/65,536**     | ✅ MATCH |

### GLSL Backend (Windows OpenGL 4.6, 128×128)

| Shader | Pattern | Different pixels | Result |
|--------|---------|------------------|--------|
| CRT (wintty) | UBO + texture | **0/16,384** | ✅ MATCH |
| Focus (wintty) | UBO + texture | **0/16,384** | ✅ MATCH |
| Branch | if/else | **0/16,384** | ✅ MATCH |
| Loop | for loop | **0/16,384** | ✅ MATCH |
| Switch | switch/case | **0/16,384** | ✅ MATCH |
| Math | sin/cos/sqrt/pow | **0/16,384** | ✅ MATCH |
| Struct | struct + distance | **0/16,384** | ✅ MATCH |
| Nested loop | 8×8 nested for | **0/16,384** | ✅ MATCH |

### HLSL Backend (Windows DXC validation, compiler-level)

| Shader | glslpp bytes | DXC result |
|--------|-------------|------------|
| CRT    | 6074        | ✅ Pass (ps_6_0) |
| Focus  | 2417        | ✅ Pass (ps_6_0) |

### Summary
- **10 shaders validated** across 2 GPU backends (Metal + OpenGL)
- **0 different pixels** in every test
- glslpp output is **byte-identical** in rendered output to spirv-cross/original GLSL

### Tools
- `tools/ShaderCompare.swift` — macOS Metal single-shader comparison
- `tools/ShaderBatchCompare.swift` — macOS Metal batch comparison
- `tools/gl_render_compare.c` — Windows OpenGL rendering comparison
- `tools/batch_compare.py` — Python batch orchestrator
