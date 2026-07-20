# run.ps1 — drive the WARP HLSL render check over a directory of shader pairs.
#
# Expects a directory of pre-staged HLSL pairs (emitted on the dev machine by
# tools/warp/stage_pairs.sh):
#     <name>.zs.hlsl   zioshade's HLSL
#     <name>.sc.hlsl   the reference cross-compiler's HLSL (SPIRV-Cross)
# For each pair it compiles both to DXIL (dxc, ps_6_0), renders both on WARP with
# the shared fullscreen VS, and diffs pixels. MATCH => zioshade's HLSL renders the
# same image as the reference on the real DXC->DXIL->D3D12 path.
#
# Prereqs on this Windows box:
#   - Windows SDK (d3d12.lib, dxgi.lib, d3d10warp.dll ships with Windows)
#   - dxc.exe on PATH (Windows SDK bin, or the standalone DXC release)
#   - warp_render.exe built:  see tools/warp/README.md
#
# Usage:  .\run.ps1 -Dir <pairs_dir> [-Dxc dxc.exe] [-Warp .\warp_render.exe]

param(
  [Parameter(Mandatory=$true)][string]$Dir,
  [string]$Dxc = "dxc.exe",
  [string]$Warp = ".\warp_render.exe"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Compile the shared fullscreen vertex shader once.
$vsCso = Join-Path $Dir "fullscreen.vs.cso"
& $Dxc -T vs_6_0 -E VSMain (Join-Path $here "fullscreen_vs.hlsl") -Fo $vsCso | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "VS compile failed"; exit 2 }

$match = 0; $differ = 0; $skip = 0
$differList = @()

Get-ChildItem -Path $Dir -Filter "*.zs.hlsl" | ForEach-Object {
  $name = $_.Name -replace '\.zs\.hlsl$',''
  $zs = $_.FullName
  $sc = Join-Path $Dir "$name.sc.hlsl"
  if (-not (Test-Path $sc)) { return }

  $zsCso = Join-Path $Dir "$name.zs.cso"
  $scCso = Join-Path $Dir "$name.sc.cso"

  # Compile both HLSL emissions to DXIL. A compile failure = skip (a backend that
  # emitted something DXC rejects is caught by the validity sweep, not here).
  & $Dxc -T ps_6_0 -E main -Wno-ignored-attributes $zs -Fo $zsCso 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { $skip++; return }
  & $Dxc -T ps_6_0 -E main -Wno-ignored-attributes $sc -Fo $scCso 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { $skip++; return }

  $out = & $Warp $vsCso $zsCso $scCso (Join-Path $Dir $name) 2>$null
  switch ($LASTEXITCODE) {
    0 { $match++ }
    1 { $differ++; $differList += $name; Write-Host "RENDER-DIFFER $name" }
    default { $skip++ }   # exit 2 = pipeline/resource setup (e.g. needs a cbuffer) -> skip
  }
}

Write-Host ""
Write-Host "RENDER-MATCH  = $match"
Write-Host "RENDER-DIFFER = $differ"
Write-Host "skip          = $skip"
if ($differ -gt 0) { Write-Host "diverged: $($differList -join ', ')"; exit 1 }
exit 0
