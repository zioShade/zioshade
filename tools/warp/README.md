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
miscompile to fix. A shader that needs a cbuffer/texture/vertex-attributes is
**skipped** (this harness feeds only `SV_Position`/`gl_FragCoord`, matching the
self-contained procedural shader class the Metal harness also covers).

## One-time setup on the Windows box

1. Windows SDK + a C++ compiler (VS Build Tools "Desktop C++"). `d3d12.lib`,
   `dxgi.lib`, and `d3d10warp.dll` come with them / with Windows.
2. `dxc.exe` on `PATH` (Windows SDK `bin\x64`, or the standalone DXC release —
   the same one used by the macOS docker oracle).
3. Build the renderer once, in an **x64 Native Tools Command Prompt**:
   ```
   cl /std:c++17 /EHsc /O2 warp_render.cpp /link d3d12.lib dxgi.lib
   ```

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

Authored on macOS and **not yet run** (no Windows in the authoring session). First
run on the `ryzen7pro` box is pending SSH access (enable OpenSSH Server on Windows).
Expect to iterate on the first compile. The macOS Metal check (`hlsl_render_check.sh`)
is the already-proven, runs-anywhere complement.
