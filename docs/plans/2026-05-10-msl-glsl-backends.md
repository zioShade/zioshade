# Plan: glslpp SPIR-V → MSL and SPIR-V → GLSL Backends

**Goal:** Build MSL and GLSL cross-compilation backends in glslpp so that wintty (and upstream ghostty) can fully replace glslang + spirv-cross with a single pure-Zig dependency.

**Architecture insight:** The existing `spirv_to_hlsl.zig` (2077 lines) has a clean separation between:
1. **SPIR-V parser** (~200 lines) — parses binary into instruction stream, builds ID maps
2. **Resource collection** (~400 lines) — resolves types, decorations, cbuffer/texture bindings  
3. **HLSL emitter** (~1400 lines) — type names, semantics, function calls, control flow

For MSL and GLSL, we only need to swap #3. The parser and resource collector are backend-agnostic.

## Design: Shared SPIR-V Cross-Compiler Core

```
src/
  spirv_cross/
    parser.zig          ← extracted from spirv_to_hlsl.zig (parseModule, getDef, getTypeOf)
    resources.zig       ← extracted (collectNames, collectDecorations, collectResources)
    types.zig           ← shared type resolution (vec/mat/int/float/struct/array)
    hlsl_emitter.zig    ← current HLSL emission code
    msl_emitter.zig     ← NEW: Metal Shading Language emission
    glsl_emitter.zig    ← NEW: GLSL emission
    root.zig            ← public API: spirvToHLSL(), spirvToMSL(), spirvToGLSL()
```

Actually — simpler approach: keep each backend self-contained but extract the shared parser into a common module. Each emitter imports the parser and emits its own dialect.

```
src/
  spirv_to_hlsl.zig     ← current (2077 lines), will slim down to emitter only
  spirv_to_msl.zig      ← NEW
  spirv_to_glsl.zig     ← NEW  
  spirv_cross_common.zig ← shared parser + resource collection
```

## Key Differences Per Backend

| Feature | HLSL | MSL | GLSL |
|---|---|---|---|
| **cbuffer** | `cbuffer X : register(bN)` | `struct X { ... }; constant X& buf [[buffer(N)]]` | `layout(binding=N, std140) uniform X { ... }` |
| **texture** | `Texture2D t : register(tN)` | `texture2d<float> t [[texture(N)]]` | `uniform sampler2D t` |
| **sampler** | `SamplerState s : register(sN)` | `sampler s [[sampler(N)]]` | (combined with texture) |
| **entry point** | `float4 main(...) : SV_Target` | `fragment main0_out main0(main0_in in [[stage_in]])` | `void main()` |
| **position** | `SV_Position` | `[[position]]` | `gl_FragCoord` |
| **output** | `SV_Target0` | `[[color(0)]]` | `layout(location=0) out vec4` |
| **type names** | `float4`, `uint2`, `int3` | `float4`, `uint2`, `int3` | `vec4`, `uvec2`, `ivec3` |
| **mat type** | `float4x4` (row-major) | `float4x4` (column-major) | `mat4` (column-major) |
| **texture sample** | `t.Sample(s, coord)` | `t.sample(s, coord)` | `texture(t, coord)` |
| **out param** | `out float4 x` | `thread float4& x` | `out vec4 x` |
| **mix/lerp** | `lerp(a,b,t)` | `mix(a,b,t)` | `mix(a,b,t)` |
| **frac/fract** | `frac(x)` | `fract(x)` | `fract(x)` |
| **ddx/ddy** | `ddx(x)` / `ddy(x)` | `dfdx(x)` / `dfdy(x)` | `dFdx(x)` / `dFdy(x)` |
| **mod** | `fmod(x,y)` | custom `mod(x,y)` template | `mod(x,y)` |
| **mul(mat,vec)** | `mul(M, v)` | `M * v` | `M * v` |
| **includes** | (none) | `#include <metal_stdlib>` | (none) |
| **version** | (none) | (none) | `#version 430` |

## Implementation Order

### Phase 1: Extract shared parser (1-2 days)
- Extract `parseModule`, `ParsedModule`, `getDef`, `getTypeOf`, `collectNames`, `collectDecorations`, `collectResources`, constant resolution from `spirv_to_hlsl.zig` into `spirv_cross_common.zig`
- Refactor `spirv_to_hlsl.zig` to import from common module
- Verify all 751 HLSL tests still pass

### Phase 2: GLSL backend (2-3 days)
Simplest backend — closest to SPIR-V semantics.
- Type names: vec4, ivec3, uvec2, mat4, etc.
- Uniform blocks: `layout(binding=N, std140) uniform Name { ... };`
- Textures: `uniform sampler2D name;`
- Entry point: `void main() { ... }`
- Built-in access: `gl_FragCoord`, `gl_FragColor`
- Functions: same names as GLSL (mix, fract, mod, dFdx, dFdy, etc.)
- No semantic annotations needed

### Phase 3: MSL backend (3-4 days)
Most complex — Metal has unique conventions.
- Struct declarations for I/O (main0_in, main0_out)
- Attribute syntax: `[[buffer(N)]]`, `[[texture(N)]]`, `[[sampler(N)]]`, `[[position]]`, `[[color(0)]]`
- `thread` references for out params
- Combined texture+sampler handling
- Header: `#include <metal_stdlib>` + `using namespace metal`
- Function templates for GLSL `mod()` compat

### Phase 4: Integration & testing (2-3 days)
- Add `spirvToMSL()` and `spirvToGLSL()` to `src/root.zig`
- Add test suites for each backend (mirroring HLSL test structure)
- Validate MSL with metal compiler (if available)
- Validate GLSL with glslangValidator (already on PATH)
- Wire into wintty `shadertoy.zig` for MSL/GLSL paths
- Remove glslang/spirv-cross deps from wintty

## Estimated Total: 8-12 days

## What Makes This "Objectively Better" Than spirv-cross

1. **Pure Zig** — no C++ runtime, no system deps, compiles everywhere Zig does
2. **Single dependency** — glslpp replaces both glslang AND spirv-cross
3. **In-process** — no DLL loading, no 8MB thread hacks, no ABI isolation
4. **~73x faster** for HLSL; expect similar gains for MSL/GLSL
5. **Thread-safe by default** — no process-wide init/finalize
6. **Better DCE** — glslpp already eliminates dead code that spirv-cross keeps (oricol sample)
7. **Correct bindings** — glslpp outputs register(b0) directly, no string replacement hacks
8. **Smaller binary** — no C++ static libs (~15-25MB of glslang+spirv-cross eliminated)
