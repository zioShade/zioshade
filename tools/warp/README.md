# WARP HLSL render harness (Windows)

Render-verify zioshade's HLSL on the **real** Direct3D path — `DXC -> DXIL -> D3D12
WARP` — the path wintty actually ships on Windows, which macOS cannot exercise.

This is the Windows counterpart of the macOS Metal check
(`tools/hlsl_render_check.sh`). Both render the same 256x256 fullscreen triangle and
diff pixels with the same "`MATCH` (<=1 per-channel)" verdict, so a shader that
RENDER-MATCHes on Metal *and* on WARP is verified on both runtimes.

WARP (`d3d10warp.dll`, ships with Windows) runs the whole D3D12 pipeline on the CPU,
so **no GPU is needed** — but it runs the true DXIL/D3D12 runtime, which is the point.

## What it proves

`run.ps1` compiles, for each shader, both zioshade's HLSL and SPIRV-Cross's HLSL to
DXIL and renders both on WARP. A **RENDER-MATCH** means zioshade's HLSL produces the
same image as the reference cross-compiler on the real D3D path — the strongest HLSL
correctness signal there is short of a hardware GPU. A **RENDER-DIFFER** is a real
miscompile to fix. The harness also binds one root CBV at `b0` holding a known
asymmetric mat4, so a `cbuffer A : register(b0) { float4x4 m; }` shader that
multiplies a uniform matrix is render-verified too (#498) — its transpose is
distinct, so a wrong-major multiply renders differently. Self-contained shaders
don't reference `b0` and are unaffected. A shader that needs a texture or vertex
attributes still **skips** (the harness feeds only `SV_Position`/`gl_FragCoord`
plus that one cbuffer).

## One-time setup on the Windows box

1. Windows SDK + a C++ compiler (VS Build Tools "Desktop C++"). `d3d12.lib`,
   `dxgi.lib`, and `d3d10warp.dll` come with them / with Windows.
2. `dxc.exe` on `PATH` (Windows SDK `bin\x64`, or the standalone DXC release —
   the same one used by the macOS docker oracle).
3. Build the renderer once. With a full "Desktop C++" MSVC install, from an **x64
   Native Tools Command Prompt**:
   ```
   cl /std:c++17 /EHsc /O2 warp_render.cpp /link d3d12.lib dxgi.lib
   ```
   If `cl`/`vcvars64` are unavailable (VS installed without the C++ workload) but
   LLVM + the MSVC toolset headers + the Windows SDK are present — as on the
   `ryzen7pro` box — build with clang-cl + lld and explicit toolset/SDK paths
   (this is the recipe that actually built it there):
   ```bat
   set "PATH=C:\Program Files\LLVM\bin;%PATH%"
   set "MSVC=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231"
   set "SDK=C:\Program Files (x86)\Windows Kits\10"
   set "SDKVER=10.0.26100.0"
   set "INCLUDE=%MSVC%\include;%SDK%\Include\%SDKVER%\ucrt;%SDK%\Include\%SDKVER%\um;%SDK%\Include\%SDKVER%\shared;%SDK%\Include\%SDKVER%\winrt"
   set "LIB=%MSVC%\lib\x64;%SDK%\Lib\%SDKVER%\ucrt\x64;%SDK%\Lib\%SDKVER%\um\x64"
   clang-cl /std:c++17 /EHsc /O2 /D_CRT_SECURE_NO_WARNINGS warp_render.cpp /Fe:warp_render.exe -fuse-ld=lld /link d3d12.lib dxgi.lib
   ```
   The pixel-shader DXIL must be compiled by a **DXIL-capable** dxc (has `dxil.dll`
   next to it) — the Windows SDK dxc, NOT the Vulkan SDK dxc (SPIR-V only). On
   ryzen7pro that is `C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe`.

## Run

On the dev (macOS) machine, stage the shader pairs and copy them over:
```
zig build cli
tools/warp/stage_pairs.sh /tmp/warp_pairs                 # all fragment shaders
# or only the macOS RENDER-MATCH subset:
# tools/hlsl_render_check.sh --sweep > sweep.txt
# grep RENDER-MATCH sweep.txt | awk '{print $2}' > names.txt   # (adjust to sweep format)
# tools/warp/stage_pairs.sh /tmp/warp_pairs tests/spirv-cross names.txt
scp -r /tmp/warp_pairs  <win>:C:/warp_pairs
scp tools/warp/*        <win>:C:/warp/
```
On Windows:
```
cd C:\warp
cl /std:c++17 /EHsc /O2 warp_render.cpp /link d3d12.lib dxgi.lib
powershell -ExecutionPolicy Bypass -File run.ps1 -Dir C:\warp_pairs
```
Output is a `RENDER-MATCH / RENDER-DIFFER / skip` tally, with every diverging shader
named. Exit code 1 if any shader diverged, so it doubles as a gate.

## Files

- `fullscreen_vs.hlsl` — SV_VertexID fullscreen triangle (mirrors the Metal VS).
- `warp_render.cpp`    — D3D12 WARP host: renders two DXIL pixel shaders, diffs pixels.
- `run.ps1`            — compile pairs to DXIL + render + diff + tally.
- `stage_pairs.sh`     — (run on the dev machine) emit the zioshade/SPIRV-Cross HLSL pairs.

## Status

**Run and green on `ryzen7pro` (Windows 11, D3D12 WARP).** Over an 8-shader set:
`RENDER-MATCH = 5` (controls: mat_branch/mat2, outer_product, mandelbrot_smooth,
swizzle_access, struct_tern), `RENDER-DIFFER = 3` — `mat3_branch`,
`mat_cond_swizzle`, `outer_product_test` — the exact three the macOS Metal proxy
predicted. So the harness works end-to-end and **confirms a real zioshade HLSL
matrix bug on the shipping DXC->DXIL->D3D12 runtime**: HLSL's `floatCxR(a,b,c)`
constructor fills ROWS (MSL's `matCxR` fills columns), so zioshade building a matrix
from GLSL columns stores the transpose, and `mul(M, v)` then computes M^T*v. SPIRV-
Cross stores the same transpose but compensates with `mul(v, M)`. Fix is a matrix-
convention correction in `spirv_to_hlsl.zig` (mul operand order + construction/
indexing/inverse consistency), verifiable via `tools/hlsl_render_check.sh` (fast,
macOS) and re-confirmable here.
