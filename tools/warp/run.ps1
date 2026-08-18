# run.ps1 — drive the WARP HLSL render check over a directory of shader pairs.
#
# Expects a directory of pre-staged HLSL pairs (emitted on the dev machine by
# tools/warp/stage_pairs.sh):
#     <name>.zs.hlsl   zioshade's HLSL
#     <name>.sc.hlsl   the reference cross-compiler's HLSL (SPIRV-Cross)
# For each pair it compiles both to DXIL (dxc, ps_6_0), renders both on WARP with
# a shared fullscreen VS, and diffs pixels. MATCH => zioshade's HLSL renders the
# same image as the reference on the real DXC->DXIL->D3D12 path.
#
# Prereqs on this Windows box:
#   - Windows SDK (d3d12.lib, dxgi.lib, d3d10warp.dll ships with Windows)
#   - dxc.exe (Windows SDK bin - the DXIL-capable one, NOT the Vulkan SDK dxc)
#   - warp_render.exe built:  see tools/warp/README.md
#
# Usage:  .\run.ps1 -Dir <pairs_dir> [-Dxc dxc.exe] [-Warp .\warp_render.exe]

param(
  [Parameter(Mandatory=$true)][string]$Dir,
  [string]$Dxc = "dxc.exe",
  [string]$Warp = ".\warp_render.exe"
)

# SilentlyContinue (not Stop): warp_render writes "shader needs resources? -> skip" to
# stderr while exiting code 2 for resource-needing shaders, and dxc writes stderr on
# rejected shaders — under "Stop" those native-stderr lines halt the script via
# NativeCommandError before the $LASTEXITCODE switch below can classify them. The
# $LASTEXITCODE checks already handle every real failure, so "Stop" only footguns the
# full-corpus sweep. SilentlyContinue lets skips/rejects flow to the switch cleanly.
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Compile the shared fullscreen vertex shader once (for varyings-free fragments).
$vsCso = Join-Path $Dir "fullscreen.vs.cso"
& $Dxc -T vs_6_0 -E VSMain (Join-Path $here "fullscreen_vs.hlsl") -Fo $vsCso | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "VS compile failed"; exit 2 }

# A fragment that reads a varying (`in vec2 uv` -> `float2 uv : TEXCOORD0`) cannot
# link against the plain fullscreen VS (which writes only SV_Position): PSO creation
# fails with E_INVALIDARG and the shader skips - on a 72-shader slice that was 27
# skips, including every uniform-matrix probe. Mirroring the macOS ShaderCompare
# trick (a per-fragment synthesized VS), extract the entry's inputs from zioshade's
# HLSL and compile a per-shader VS that writes them. CRITICAL D3D12 linkage detail
# (established empirically on WARP): a PS input links to the VS output at the SAME
# SLOT with the SAME semantic and type - a VS whose SV_Position sits in slot 0
# cannot feed a PS whose slot 0 is TEXCOORD0, regardless of semantics. So the
# generated VS mirrors the PS parameter list IN ORDER, and appends SV_Position at
# the END only when the PS does not declare it (extra trailing VS outputs are
# legal). Both sides render against the SAME VS, so the differential stays fair.
# Values are NDC-derived (spatially varying, stronger signal than Metal's
# zero-filled varyings).
#   $hlsl -> @(@{Sem,Type,Interp}, ...) in param order, or $null when unsupported.
function Get-Varyings([string]$hlsl) {
  $vary = @()
  $sig = Select-String -Path $hlsl -Pattern 'main\s*\([^)]*\)' | Select-Object -First 1
  if (-not $sig) { return $vary }
  $re = '(?:(nointerpolation|centroid|noperspective|precise)\s+)?([A-Za-z_][A-Za-z_0-9]*)\s+[A-Za-z_][A-Za-z_0-9]*\s*:\s*([A-Za-z_][A-Za-z_0-9]*\d*)'
  foreach ($m in [regex]::Matches($sig.Matches[0].Value, $re)) {
    $vary += @{ Sem = $m.Groups[3].Value; Type = $m.Groups[2].Value; Interp = $m.Groups[1].Value }
  }
  return ,$vary
}

function New-VsCso([string]$name, [object]$vary) {
  $members = ""; $writes = ""; $hasPos = $false
  foreach ($v in $vary) {
    if ($v.Sem -eq "SV_Position") { $hasPos = $true; $members += "    float4 _p : SV_Position;`n"; continue }
    # Anything else (an `out float gl_FragDepth : SV_Depth` param, other system
    # values) is not a varying the VS must feed: mirror only TEXCOORD inputs. A PS
    # genuinely READING another system input will fail PSO creation at render time
    # and skip, which is the correct out-of-scope signal.
    if ($v.Sem -notmatch '^TEXCOORD\d+$') { continue }
    $field = "t" + ($v.Sem -replace '\D','')
    $base = $v.Type -replace '\d+$', ''
    $n = if ($v.Type -match '\d+$') { [int]($Matches[0]) } else { 1 }
    if ($base -notin @('float','half','int','uint','bool')) { return $null }
    $decl = if ($v.Interp) { "$($v.Interp) " } else { "" }
    $members += "    $decl$($v.Type) $field : $($v.Sem);`n"
    if ($base -eq 'int' -or $base -eq 'uint' -or $base -eq 'bool') {
      $iv = "(vid == 2) ? 1 : 0"
      $rest = if ($n -gt 1) { (1..($n-1)) | ForEach-Object { ", 0" } } else { @() }
      $zero = if ($base -eq 'uint') { "u" } else { "" }
      $writes += "    o.$field = $($v.Type)($iv$($rest -join '')$zero);`n"
    } else {
      $vals = switch ($n) { 1 { "p.x" } 2 { "p.x, p.y" } 3 { "p.x, p.y, 0.5" } 4 { "p.x, p.y, 0.5, 1.0" } }
      $writes += "    o.$field = $($v.Type)($vals);`n"
    }
  }
  if (-not $hasPos) { $members += "    float4 _p : SV_Position;`n" }
  $src = @"
struct VSOUT_V
{
$members
};
VSOUT_V VSMain(uint vid : SV_VertexID)
{
    float2 p;
    p.x = (vid == 2) ? 3.0 : -1.0;
    p.y = (vid == 0) ? -3.0 : 1.0;
    VSOUT_V o;
    o._p = float4(p, 0.0, 1.0);
$writes
    return o;
}
"@
  $srcPath = Join-Path $Dir "$name.gen_vs.hlsl"
  $csoPath = Join-Path $Dir "$name.gen_vs.cso"
  [IO.File]::WriteAllText($srcPath, $src)
  & $Dxc -T vs_6_0 -E VSMain $srcPath -Fo $csoPath | Out-Null
  if ($LASTEXITCODE -ne 0) { return $null }
  return $csoPath
}

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
  if ($LASTEXITCODE -ne 0) { Write-Host "skip dxc-zs $name"; $skip++; return }
  & $Dxc -T ps_6_0 -E main -Wno-ignored-attributes $sc -Fo $scCso 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "skip dxc-sc $name"; $skip++; return }

  # Per-shader VS when the fragment reads varyings; shared fullscreen VS otherwise.
  $useVs = $vsCso
  $vary = Get-Varyings $zs
  if ($null -ne $vary -and $vary.Count -gt 0) {
    $genVs = New-VsCso $name $vary
    if ($null -eq $genVs) { Write-Host "skip gen-vs $name"; $skip++; return }
    $useVs = $genVs
  }

  $out = & $Warp $useVs $zsCso $scCso (Join-Path $Dir $name) 2>$null
  switch ($LASTEXITCODE) {
    0 { $match++ }
    1 { $differ++; $differList += $name; Write-Host "RENDER-DIFFER $name" }
    default { Write-Host "skip warp-$LASTEXITCODE $name"; $skip++ }   # exit 2 = PSO/resource setup -> skip
  }
}

Write-Host ""
Write-Host "RENDER-MATCH  = $match"
Write-Host "RENDER-DIFFER = $differ"
Write-Host "skip          = $skip"
if ($differ -gt 0) { Write-Host "diverged: $($differList -join ', ')"; exit 1 }
exit 0
