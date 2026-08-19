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
don't reference `b0` and are unaffected. Varying-input (`in vec2 uv`) shaders render
too via the per-shader VS (see "Run"). A shader that needs a texture, or more
buffers than the one b0 CBV, still **skips** (the harness binds no textures and one
cbuffer).

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

On the dev (macOS) machine, stage the shader pairs and copy them over (`just warp-render`
automates this when `WARP_HOST` is set):
```
zig build cli
tools/warp/stage_pairs.sh /tmp/warp_pairs                 # all fragment shaders
# or only a named subset (e.g. the macOS RENDER-MATCH list):
# tools/hlsl_render_check.sh --sweep > sweep.txt
# grep RENDER-MATCH sweep.txt | awk '{print $2}' > names.txt   # (adjust to sweep format)
# tools/warp/stage_pairs.sh /tmp/warp_pairs tests/spirv-cross names.txt
scp -r /tmp/warp_pairs  <win>:C:/warp_pairs
scp tools/warp/*        <win>:C:/warp/
```
On Windows:
```
cd C:\warp
cl /std:c++17 /EHsc /O2 warp_render.cpp /link d3d12.lib dxgi.lib    # or the clang-cl recipe above
powershell -ExecutionPolicy Bypass -File run.ps1 -Dir C:\warp_pairs -Dxc <SDK-dxc> -Warp .\warp_render.exe
```
`-Dxc` must point at the Windows SDK dxc (DXIL-capable); on PATH the Vulkan SDK dxc
would be picked, which cannot emit DXIL. Output is a `RENDER-MATCH / RENDER-DIFFER /
skip` tally with a per-skip reason line (`skip dxc-zs|dxc-sc|gen-vs|warp-2 <name>`),
and names every diverging shader. Exit code 1 if any shader diverged, so it doubles
as a gate.

### Varying-input shaders (per-shader VS)

`run.ps1` compiles a PER-SHADER fullscreen vertex shader for fragments that read
varyings (`in vec2 uv` -> `float2 uv : TEXCOORD0`), mirroring the macOS ShaderCompare
trick of a synthesized per-fragment VS. The reason is a D3D12 linkage rule established
empirically on WARP: **a PS input links to the VS output at the SAME SLOT, with the
same semantic and type** - a VS whose SV_Position sits in slot 0 cannot feed a PS whose
slot 0 is TEXCOORD0 (PSO creation fails with E_INVALIDARG), and leading extra VS
outputs shift every PS input off its slot. So the generated VS mirrors the PS
parameter list in order (NDC-derived values, spatially varying) and appends
SV_Position only when the PS does not declare it (trailing extra VS outputs are
legal). Without this, 27 of a 72-shader slice skipped - including every
uniform-matrix probe. Remaining skip classes: shaders whose bindings exceed the one
b0 CBV the harness binds (declares b1+), and hostile inputs DXC rejects from either
compiler (e.g. types.flatten: three UBOs all at binding 0).

## Files

- `fullscreen_vs.hlsl` — SV_VertexID fullscreen triangle (mirrors the Metal VS).
- `warp_render.cpp`    — D3D12 WARP host: renders two DXIL pixel shaders, diffs pixels.
- `run.ps1`            — compile pairs to DXIL + render + diff + tally.
- `stage_pairs.sh`     — (run on the dev machine) emit the zioshade/SPIRV-Cross HLSL pairs.

## Status

**First end-to-end run on the real runtime: 2026-08-18, `ryzen7pro` (Windows 11,
D3D12 WARP, SDK 10.0.26100.0 dxc).** Over a 72-shader strided slice of
tests/spirv-cross (63 pure-gl_FragCoord/varying + 9 b0-cbuffer probes):
`RENDER-MATCH = 70, RENDER-DIFFER = 0, skip = 2`; re-confirmed over a 300-shader
strided slice: `RENDER-MATCH = 297, RENDER-DIFFER = 0, skip = 3` (the two below
plus `pack_unpack`, see the validity note at the end).

That run found and closed two things:

1. **A real HLSL miscompile (fixed):** a fragment with NO color outputs got a
   synthesized `float4 main(...) : SV_Target` returning `(0,0,0,0)` - writing
   black-transparent to target 0 on every pixel where GLSL/SPIR-V semantics write
   NOTHING (the attachment keeps its prior contents). WARP verdict: RENDER-DIFFER
   maxdiff 255 on all 65536 px (alpha flip) for `depth-less-than.desktop` and
   `partial-write-preserve`; the macOS Metal proxy independently flagged the same
   class (`RENDER-DIFFER px=65536,maxdiff=255`). Fix: emit a `void main(...)` entry
   with no SV_Target (spirv-cross's shape), keep early OpReturns as `return;`.
   After the fix both shaders RENDER-MATCH on WARP; `partial-write-preserve` also
   RENDER-MATCHes on Metal.
2. **The same bug existed in the MSL backend** (synthesized `float4 _fragColor
   [[color(0)]]` written as zeros for no-output fragments); fixed the same way
   (`fragment void main0(...)`) and render-verified on Metal (RENDER-MATCH).

The 2 remaining skips are scope, not defects: `types.flatten` (GLSL declares three
UBOs at binding 0; DXC rejects both compilers' output - hostile input) and
`ubo-load-row-major-workaround` (declares b0..b3; the harness root signature binds
one CBV at b0 - see "Varying-input shaders" above for the skip census).

Also noted (not fixed, not render-visible with depth disabled): zioshade maps
`gl_FragDepth` to plain `SV_Depth` and ignores the DepthLess/DepthGreater execution
modes; spirv-cross maps them to `SV_DepthLessEqual`/`SV_DepthGreaterEqual`. The
current emission is conservative (unconstrained depth write), not a miscompile, but
the fidelity gap is real. And `pack_unpack` exposed an HLSL validity gap: the whole
std450 pack/unpack family (#56 PackSnorm2x16, #57 PackUnorm2x16, #60 UnpackSnorm2x16,
#61 UnpackUnorm2x16) emitted `// unhandled std450` comments but still referenced the
result IDs, so DXC rejected the output (undeclared identifier) while the MSL backend
lowers them inline and WGSL maps them. FIXED since: the HLSL backend now lowers
54-57/60/61/63/64 to spirv-cross-verbatim `spvPack*`/`spvUnpack*` helpers (58/62 were
already inlined via f32tof16/f16tof32; 59/65 double-refuse per the #476 64-bit gate),
DXC-verified at ps_6_0; `pack_unpack` compiles clean, so the next run can drop that
skip.

Earlier README text claimed a July run with a matrix-convention DIFFER set; that
came from an unmerged branch's history, not the shipping harness, and is superseded
by the verified run above.
