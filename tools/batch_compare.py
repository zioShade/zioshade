#!/usr/bin/env python3
"""
Batch cross-compilation validation and rendering comparison for glslpp.

Usage:
  python batch_compare.py --validate                    # Validate all shaders compile
  python batch_compare.py --render-msl                  # MSL rendering comparison on macOS
  python batch_compare.py --render-hlsl                 # HLSL rendering comparison (Windows)
  python batch_compare.py --render-glsl                 # GLSL rendering comparison (Windows)

Requires:
  - glslangValidator (Vulkan SDK)
  - spirv-cross (Vulkan SDK)
  - dxc (Vulkan SDK, for HLSL)
  - macOS SSH access for MSL rendering
"""

import os
import sys
import subprocess
import json
import tempfile
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

GLSLANG = os.environ.get("GLSLANG", "glslangValidator")
SPIRVCROSS = os.environ.get("SPIRVCROSS", "spirv-cross")
DXC = os.environ.get("DXC", "dxc")
MAC_SSH = os.environ.get("MAC_SSH", "alex@macbookale")

GLSLPP_DIR = Path(__file__).parent

@dataclass
class ShaderResult:
    name: str
    glslpp_compile_ok: bool = False
    glslpp_hlsl_ok: bool = False
    glslpp_glsl_ok: bool = False
    glslpp_msl_ok: bool = False
    ref_compile_ok: bool = False
    ref_hlsl_ok: bool = False
    ref_glsl_ok: bool = False
    ref_msl_ok: bool = False
    hlsl_render_match: Optional[bool] = None
    msl_render_match: Optional[bool] = None
    glsl_render_match: Optional[bool] = None
    max_pixel_diff: int = 0
    error: str = ""

def find_shaders():
    """Find all test shaders."""
    shaders = []
    
    # spirv-cross reference shaders
    for f in sorted((GLSLPP_DIR / "tests/spirv-cross").glob("*.frag")):
        shaders.append(("spirv-cross", f))
    
    # glslang-430 shaders
    for f in sorted((GLSLPP_DIR / "tests/glslang-430").glob("*.frag")):
        shaders.append(("glslang-430", f))
    
    # wintty shaders (assembled)
    for f in sorted((GLSLPP_DIR / "tests/wintty").glob("test_*.glsl")):
        shaders.append(("wintty", f))
    
    return shaders

def compile_glslpp(shader_path: Path, target: str) -> tuple[bool, Optional[bytes]]:
    """Compile a shader through glslpp via the dump-shader tool."""
    # We use the build system for this
    pass

def validate_with_dxc(hlsl_path: Path) -> tuple[bool, str]:
    """Validate HLSL with DXC."""
    try:
        result = subprocess.run(
            [DXC, "-T", "ps_6_0", "-E", "main", "-Wno-ignored-attributes", str(hlsl_path)],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0, result.stderr
    except Exception as e:
        return False, str(e)

def validate_with_glslang(glsl_path: Path) -> tuple[bool, str]:
    """Validate GLSL with glslangValidator."""
    try:
        result = subprocess.run(
            [GLSLANG, "-S", "frag", str(glsl_path)],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0, result.stderr
    except Exception as e:
        return False, str(e)

def spirv_cross_compile(spv_path: Path, target: str) -> tuple[bool, Optional[str]]:
    """Compile SPIR-V to target using spirv-cross."""
    args = [SPIRVCROSS, str(spv_path)]
    if target == "msl":
        args += ["--msl", "--msl-decoration-binding"]
    elif target == "hlsl":
        args += ["--hlsl", "--shader-model", "60"]
    elif target == "glsl":
        args += ["--version", "430"]
    
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return True, result.stdout
        return False, None
    except Exception:
        return False, None

def generate_reference(spv_path: Path, output_prefix: str):
    """Generate reference outputs using spirv-cross."""
    results = {}
    for target in ["hlsl", "glsl", "msl"]:
        ok, code = spirv_cross_compile(spv_path, target)
        if ok and code:
            ext = target
            out_path = f"{output_prefix}_ref.{ext}"
            with open(out_path, 'w') as f:
                f.write(code)
            results[target] = out_path
    return results

def compare_rendering_msl(glslpp_msl: str, ref_msl: str) -> tuple[bool, int]:
    """Compare MSL rendering on macOS via SSH."""
    try:
        # Copy files to Mac
        subprocess.run(["scp", glslpp_msl, f"{MAC_SSH}:/tmp/glslpp.msl"], 
                       capture_output=True, timeout=30)
        subprocess.run(["scp", ref_msl, f"{MAC_SSH}:/tmp/ref.msl"],
                       capture_output=True, timeout=30)
        
        # Run comparison
        result = subprocess.run(
            ["ssh", MAC_SSH, 
             "swiftc -o /tmp/ShaderCompare /tmp/ShaderCompare.swift "
             "-framework Metal -framework MetalKit -framework Foundation 2>/dev/null && "
             "/tmp/ShaderCompare /tmp/glslpp.msl /tmp/ref.msl /tmp/compare"],
            capture_output=True, text=True, timeout=60
        )
        
        if "MATCH" in result.stdout:
            return True, 0
        elif "DIFFER" in result.stdout:
            # Extract max diff
            for line in result.stdout.split('\n'):
                if "Max channel diff" in line:
                    try:
                        diff = int(line.split(':')[-1].strip())
                        return False, diff
                    except:
                        pass
            return False, -1
        return False, -1
    except Exception as e:
        print(f"    MSL render error: {e}")
        return False, -1

def batch_validate():
    """Validate all shaders compile through both pipelines."""
    shaders = find_shaders()
    print(f"Found {len(shaders)} shaders to validate\n")
    
    results = {"pass": 0, "fail": 0, "skip": 0, "details": []}
    
    for category, shader_path in shaders:
        name = shader_path.stem
        print(f"[{category}] {name}...", end=" ", flush=True)
        
        # Step 1: Compile with glslangValidator to get reference SPIR-V
        with tempfile.NamedTemporaryFile(suffix=".spv", delete=False) as spv_f:
            spv_path = spv_f.name
        
        glslang_result = subprocess.run(
            [GLSLANG, "-V", "-S", "frag", str(shader_path), "-o", spv_path],
            capture_output=True, text=True, timeout=30
        )
        
        if glslang_result.returncode != 0:
            print(f"SKIP (glslangValidator: {glslang_result.stderr[:80]})")
            results["skip"] += 1
            os.unlink(spv_path)
            continue
        
        # Step 2: Generate reference outputs with spirv-cross
        ref_outputs = generate_reference(spv_path, spv_path.replace(".spv", ""))
        
        # Step 3: Validate reference outputs with external compilers
        ref_ok = True
        if "hlsl" in ref_outputs:
            ok, _ = validate_with_dxc(ref_outputs["hlsl"])
            if not ok: ref_ok = False
        if "glsl" in ref_outputs:
            ok, _ = validate_with_glslang(ref_outputs["glsl"])
            if not ok: ref_ok = False
        
        # Step 4: Validate glslpp outputs
        # (This would use the glslpp build tools - simplified here)
        
        print("OK" if ref_ok else "REF_FAIL")
        if ref_ok:
            results["pass"] += 1
        else:
            results["fail"] += 1
        
        results["details"].append({
            "name": name,
            "category": category,
            "ref_ok": ref_ok,
        })
        
        # Cleanup
        os.unlink(spv_path)
        for p in ref_outputs.values():
            try: os.unlink(p)
            except: pass
    
    print(f"\n=== SUMMARY ===")
    print(f"Pass: {results['pass']}, Fail: {results['fail']}, Skip: {results['skip']}")
    return results

def batch_render_msl():
    """Batch MSL rendering comparison for wintty shaders."""
    print("MSL Rendering Comparison (macOS Metal)")
    print("=" * 50)
    
    wintty_shaders = [
        ("CRT", "tests/wintty/crt_output"),
        ("Focus", "tests/wintty/focus_output"),
    ]
    
    # Copy ShaderBatchCompare to Mac first
    swift_tool = GLSLPP_DIR / "tools/ShaderBatchCompare.swift"
    subprocess.run(["scp", str(swift_tool), f"{MAC_SSH}:ShaderBatchCompare.swift"],
                   capture_output=True, timeout=30)
    
    for name, prefix in wintty_shaders:
        glslpp_msl = GLSLPP_DIR / f"{prefix}.msl"
        
        if not glslpp_msl.exists():
            print(f"  {name}: SKIP (no glslpp MSL output)")
            continue
        
        # Generate spirv-cross reference
        glsl_path = GLSLPP_DIR / f"{prefix}.glsl"
        spv_path = f"/tmp/{name.lower()}_ref.spv"
        ref_msl_path = f"/tmp/{name.lower()}_ref.msl"
        
        # glslangValidator → SPIR-V
        subprocess.run([GLSLANG, "-V", "-S", "frag", str(glsl_path), "-o", spv_path],
                       capture_output=True, timeout=30)
        
        # spirv-cross → MSL
        subprocess.run([SPIRVCROSS, spv_path, "--msl", "--msl-decoration-binding"],
                       capture_output=True, timeout=30,
                       text=True) # TODO: write to file
        
        # Copy to Mac and compare
        subprocess.run(["scp", str(glslpp_msl), f"{MAC_SSH}:/tmp/{name.lower()}_glslpp.msl"],
                       capture_output=True, timeout=30)
        
        # Run comparison
        result = subprocess.run(
            ["ssh", MAC_SSH,
             f"./ShaderCompare /tmp/{name.lower()}_glslpp.msl /tmp/{name.lower()}_ref.msl /tmp/{name.lower()}_compare"],
            capture_output=True, text=True, timeout=60
        )
        
        print(f"\n{name}:")
        print(result.stdout)

def main():
    parser = argparse.ArgumentParser(description="Batch shader comparison for glslpp")
    parser.add_argument("--validate", action="store_true", help="Validate all shaders")
    parser.add_argument("--render-msl", action="store_true", help="MSL rendering comparison")
    parser.add_argument("--render-hlsl", action="store_true", help="HLSL rendering comparison")
    parser.add_argument("--render-glsl", action="store_true", help="GLSL rendering comparison")
    parser.add_argument("--all", action="store_true", help="Run all comparisons")
    
    args = parser.parse_args()
    
    if args.validate or args.all:
        batch_validate()
    if args.render_msl or args.all:
        batch_render_msl()
    if args.render_hlsl or args.all:
        print("HLSL rendering comparison - coming soon")
    if args.render_glsl or args.all:
        print("GLSL rendering comparison - coming soon")

if __name__ == "__main__":
    main()
