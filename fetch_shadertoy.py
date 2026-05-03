#!/usr/bin/env python3
"""
Fetch popular Shadertoy shaders and prepare them for testing with glslpp.
Uses the Shadertoy API to fetch shader code, then wraps it with the wintty
shadertoy prefix.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error

SHADERTOY_API_KEY = "BHd8dM"  # Public demo key
SHADERTOY_API_URL = "https://www.shadertoy.com/api/v1/shaders/{}"

# Diverse set of popular Shadertoy shaders covering different feature sets:
# - Ray marching, SDFs
# - 2D effects (post-processing, fractals)
# - Textures/noise
# - Math functions
# - Image processing
# - Various GLSL constructs (loops, conditionals, arrays, matrices)
SHADER_IDS = [
    # Simple/2D shaders
    "4sfGDB",  # Seascape (waves) - moderate complexity
    "XsXXDn",  # "Happy Jumping" - ray marching
    "4ttSWf",  # Balloons
    "MsjSW3",  # Rainforest
    "ldScRG",  # Dust particles
    "MdscWt",  # Volcanic
    "Xtl3D2",  # Fractal noise
    "4sBSGG",  # Fires
    "Xds3zN",  # SDF scene
    "3lj3zw",  # Worms
    "XtGGRt",  # Raymarching basic
    "4dKfzG",  # Heart
    "4sX3zs",  # Procedural noise
    "4dl3zn",  # Post-processing
    "XsVBzw",  # Fractal
    "MldcD8",  # Clouds
    "4djSRy",  # Soft shadow raymarching
    "XdVyD0",  # Postprocessing / bloom
    "MlKSWm",  # Nebula
    "XsBXWt",  # Stars
]

WINTTY_PREFIX = r"""#version 430 core

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
};

layout(binding = 0) uniform sampler2D iChannel0;
layout(binding = 1) uniform sampler2D iChannel1;
layout(binding = 2) uniform sampler2D iChannel2;
layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );
void main() { mainImage (_fragColor, gl_FragCoord.xy); }
"""

GLSLPP_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.zig-cache', 'bin', 'conformance-runner.exe')
SPIRV_VAL = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe'
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'shadertoy_test_cache')


def fetch_shader(shader_id):
    """Fetch shader code from Shadertoy API."""
    url = SHADERTOY_API_URL.format(shader_id) + "?key=" + SHADERTOY_API_KEY
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        return None, f"fetch error: {e}"
    
    if data.get('Error', '') != '':
        return None, f"API error: {data['Error']}"
    
    shader = data.get('Shader', {})
    info = shader.get('info', {})
    name = info.get('name', shader_id)
    
    renderpass = shader.get('renderpass', [])
    if not renderpass:
        return None, "no renderpass"
    
    # Get the image pass (main shader code)
    code = None
    for rp in renderpass:
        if rp.get('type') == 'image':
            code = rp.get('code', '')
            break
    
    if code is None:
        # Use first pass
        code = renderpass[0].get('code', '')
    
    return {
        'id': shader_id,
        'name': name,
        'code': code,
    }, None


def prepare_shader(shader_info):
    """Wrap shader code with the wintty prefix."""
    code = shader_info['code']
    
    # Remove any existing #version directive from the shader code
    lines = code.split('\n')
    filtered = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#version'):
            continue
        # Remove Shadertoy-specific defines that our prefix doesn't have
        if 'iChannel' in stripped and 'uniform' in stripped and 'sampler' in stripped:
            continue
        filtered.append(line)
    
    return WINTTY_PREFIX + '\n\n' + '\n'.join(filtered)


def compile_glslpp(source, output_path):
    """Compile GLSL to SPIR-V using glslpp."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.glsl', delete=False, encoding='utf-8') as f:
        f.write(source)
        temp_path = f.name
    
    try:
        result = subprocess.run(
            [GLSLPP_RUNNER, temp_path, '--save-spv', output_path],
            capture_output=True, text=True, timeout=15
        )
        if os.path.exists(output_path):
            return True, result.stdout + result.stderr
        else:
            return False, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)
    finally:
        os.unlink(temp_path)


def validate_spv(path):
    """Run spirv-val on a SPIR-V binary."""
    result = subprocess.run(
        [SPIRV_VAL, path],
        capture_output=True, text=True, timeout=10
    )
    return result.returncode == 0, result.stdout + result.stderr


def get_bound(path):
    """Get the Bound value from a SPIR-V binary."""
    with open(path, 'rb') as f:
        data = f.read(20)
    if len(data) < 20:
        return None
    words = struct.unpack('<5I', data)
    return words[3]


import struct

GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'


def main():
    if not os.path.exists(GLSLPP_RUNNER):
        print(f"{RED}glslpp runner not found at {GLSLPP_RUNNER}{RESET}")
        sys.exit(1)
    
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    print(f"{BLUE}Shadertoy Shader Audit: glslpp vs real-world shaders{RESET}")
    print(f"  Shaders to test: {len(SHADER_IDS)}")
    print()
    
    results = []
    for shader_id in SHADER_IDS:
        # Check cache
        cache_path = os.path.join(OUTPUT_DIR, f'{shader_id}.json')
        spv_path = os.path.join(OUTPUT_DIR, f'{shader_id}.spv')
        
        if os.path.exists(cache_path):
            with open(cache_path, 'r', encoding='utf-8') as f:
                shader_info = json.load(f)
            fetch_err = None
            print(f"  [cached] {shader_id}: {shader_info['name'][:50]}")
        else:
            shader_info, fetch_err = fetch_shader(shader_id)
            if fetch_err:
                print(f"  {RED}SKIP {shader_id}: {fetch_err}{RESET}")
                results.append({'id': shader_id, 'status': 'skip', 'error': fetch_err})
                continue
            with open(cache_path, 'w', encoding='utf-8') as f:
                json.dump(shader_info, f, ensure_ascii=False)
            print(f"  [fetched] {shader_id}: {shader_info['name'][:50]}")
        
        # Prepare full shader
        full_source = prepare_shader(shader_info)
        
        # Cache the prepared source
        src_path = os.path.join(OUTPUT_DIR, f'{shader_id}.glsl')
        with open(src_path, 'w', encoding='utf-8') as f:
            f.write(full_source)
        
        # Compile
        ok, output = compile_glslpp(full_source, spv_path)
        
        if not ok:
            # Extract error
            err_lines = [l for l in output.split('\n') if 'error' in l.lower() or 'COMPILE' in l or 'spirv-val' in l]
            err_summary = err_lines[0][:100] if err_lines else output[:100]
            print(f"    {RED}COMPILE FAIL{RESET}: {err_summary}")
            results.append({'id': shader_id, 'name': shader_info['name'], 'status': 'compile_fail', 'error': err_summary})
            continue
        
        # Validate
        valid, val_output = validate_spv(spv_path)
        if not valid:
            val_lines = [l for l in val_output.split('\n') if l.strip()]
            val_summary = val_lines[0][:100] if val_lines else val_output[:100]
            print(f"    {RED}VAL FAIL{RESET}: {val_summary}")
            results.append({'id': shader_id, 'name': shader_info['name'], 'status': 'val_fail', 'error': val_summary})
            continue
        
        bound = get_bound(spv_path)
        size = os.path.getsize(spv_path)
        print(f"    {GREEN}PASS{RESET} bound={bound} size={size}")
        results.append({'id': shader_id, 'name': shader_info['name'], 'status': 'pass', 'bound': bound, 'size': size})
        
        time.sleep(0.5)  # Rate limit API calls
    
    # Summary
    total = len(results)
    passed = sum(1 for r in results if r['status'] == 'pass')
    compile_fails = sum(1 for r in results if r['status'] == 'compile_fail')
    val_fails = sum(1 for r in results if r['status'] == 'val_fail')
    skipped = sum(1 for r in results if r['status'] == 'skip')
    total_bound = sum(r.get('bound', 0) for r in results if r['status'] == 'pass')
    
    print(f"\n{BLUE}{'='*60}{RESET}")
    print(f"{BLUE}  SUMMARY{RESET}")
    print(f"{BLUE}{'='*60}{RESET}")
    print(f"  Total:       {total}")
    print(f"  {GREEN}PASS:        {passed}{RESET}")
    print(f"  {RED}Compile fail: {compile_fails}{RESET}")
    print(f"  {RED}Val fail:     {val_fails}{RESET}")
    print(f"  {YELLOW}Skip:        {skipped}{RESET}")
    if passed > 0:
        print(f"  Total bound: {total_bound}")
        print(f"  Avg bound:   {total_bound // passed}")
    
    if compile_fails + val_fails > 0:
        print(f"\n{RED}FAILURES:{RESET}")
        for r in results:
            if r['status'] in ('compile_fail', 'val_fail'):
                print(f"  {RED}X{RESET} {r['id']} ({r.get('name', '?')[:40]}): {r.get('error', '')[:80]}")
    
    print(f"\n{BLUE}VERDICT:{RESET}")
    if passed == total:
        print(f"  {GREEN}ALL {total} SHADERTOY SHADERS PASS!{RESET}")
    elif passed > 0:
        pct = passed / total * 100
        print(f"  {YELLOW}{passed}/{total} ({pct:.0f}%) pass{RESET}")
    
    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
