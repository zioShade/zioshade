# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 conformance (95.9%), 0 val_fail, 0 leaks ✅✅
## HLSL tests: 174/174 pass, 0 fail, 0 leaked ✅✅
## Session: 131→174 HLSL (+43 tests, +32.8%), conformance 213/222 stable, leaks ALL FIXED

## All Memory Leaks Fixed!
- Session started with ~150 conformance leaks, now 0
- Fixed: parser children leaks (heap_children tracking), parser type leaks (heap_types), semantic instruction operand leaks, matrix construction temp array leaks, struct member merge leaks, StringHashMap key replacement leaks, parse() error path cleanup
- 0 double-frees, 0 leaks across both HLSL tests and conformance runner

## Next Optimization Opportunities

### High-Impact HLSL Features (New Tests)
- Non-square matrix operations (mat4x3, mat3x2, etc.) — different column/row counts
- Geometry shader EmitVertex/EndPrimitive (requires proper HLSL stream append)
- Tessellation shaders (hull/domain shaders)
- Subpass input (Vulkan render passes — Vulkan-specific, may not have HLSL equivalent)
- Workgroup/shared memory (groupshared in HLSL)
- Derivative control (dFdxCoarse/dFdxFine — may already work)

### Conformance Improvement (222 total, 213 pass, 9 skip)
- 9 SKIP files are all ERROR validation tests (// ERROR marker) — correctly skipped
- Could look at the shader files NOT found by the conformance runner (343 total - 222 tested = 121 not tested)
- Many of those 121 are .asm (assembly) or .nocompat files, correctly excluded

### Code Quality
- HLSL variable naming uses fallback "0" for unnamed IDs (quality, not correctness)
- Could improve HLSL output formatting (indentation, line breaks)
