#!/usr/bin/env python3
"""
Rendering comparison pipeline for glslpp vs spirv-cross.

Compiles fragment shaders through both pipelines and compares rendered output
pixel-by-pixel using OpenGL (gl_render_compare.exe).

Usage:
  python tools/render_compare.py                    # Compare all test shaders
  python tools/render_compare.py --shader test.glsl # Compare single shader
  python tools/render_compare.py --generate         # Generate test shaders
"""

import os
import sys
import subprocess
import tempfile
import argparse
from pathlib import Path

GLSLANG = os.environ.get("GLSLANG", "glslangValidator")
SPIRVCROSS = os.environ.get("SPIRVCROSS", "spirv-cross")
RENDER_TOOL = Path(__file__).parent / "gl_render_compare.exe"

GLSLPP_DIR = Path(__file__).parent.parent

# Simple fragment shaders designed for rendering comparison.
# Each uses only gl_FragCoord (built-in) and basic math — no textures, UBOs, etc.
RENDER_TEST_SHADERS = {
    "basic_color": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    FragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
""",
    "uv_gradient": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    FragColor = vec4(uv.x, uv.y, 0.0, 1.0);
}
""",
    "checkerboard": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float c = mod(floor(uv.x * 8.0) + floor(uv.y * 8.0), 2.0);
    FragColor = vec4(c, c, c, 1.0);
}
""",
    "circles": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float d = length(uv - vec2(0.5));
    float ring = fract(d * 10.0);
    FragColor = vec4(ring, ring * 0.5, 1.0 - ring, 1.0);
}
""",
    "branch_simple": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    if (uv.x > 0.5) {
        FragColor = vec4(1.0, 0.0, 0.0, 1.0);
    } else {
        FragColor = vec4(0.0, 0.0, 1.0, 1.0);
    }
}
""",
    "branch_nested": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec3 col = vec3(0.0);
    if (uv.x > 0.3) {
        if (uv.y > 0.3) {
            col = vec3(1.0, 0.0, 0.0);
        } else {
            col = vec3(0.0, 1.0, 0.0);
        }
    } else {
        if (uv.y > 0.7) {
            col = vec3(0.0, 0.0, 1.0);
        } else {
            col = vec3(1.0, 1.0, 0.0);
        }
    }
    FragColor = vec4(col, 1.0);
}
""",
    "for_loop_accumulate": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        sum += sin(uv.x * 3.14159 * float(i + 1)) * 0.125;
    }
    FragColor = vec4(sum, sum * 0.5, 1.0 - sum, 1.0);
}
""",
    "while_loop": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float x = uv.x;
    int n = 0;
    while (x > 0.1 && n < 10) {
        x *= 0.7;
        n++;
    }
    float c = float(n) / 10.0;
    FragColor = vec4(c, x, uv.y, 1.0);
}
""",
    "nested_loop": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float v = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            v += sin(uv.x * float(i+1) * 3.14) * cos(uv.y * float(j+1) * 3.14);
        }
    }
    v = fract(v * 0.5 + 0.5);
    FragColor = vec4(v, v * 0.7, v * 0.3, 1.0);
}
""",
    "switch_stmt": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    int quadrant = int(step(0.5, uv.x)) + 2 * int(step(0.5, uv.y));
    vec3 col;
    switch (quadrant) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        case 3: col = vec3(1.0, 1.0, 0.0); break;
        default: col = vec3(0.0); break;
    }
    FragColor = vec4(col, 1.0);
}
""",
    "math_functions": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = abs(sin(uv.x * 6.28));
    float g = abs(cos(uv.y * 6.28));
    float b = sqrt(uv.x * uv.y);
    float a = clamp(uv.x + uv.y, 0.0, 1.0);
    FragColor = vec4(r, g, b, a);
}
""",
    "vec_ops": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec3 a = vec3(uv, 0.5);
    vec3 b = vec3(0.3, uv.x, uv.y);
    vec3 c = a * b + vec3(0.1);
    c = normalize(c) * 0.5 + 0.5;
    FragColor = vec4(c, 1.0);
}
""",
    "mix_smoothstep": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float t = smoothstep(0.2, 0.8, uv.x);
    vec3 red = vec3(1.0, 0.0, 0.0);
    vec3 blue = vec3(0.0, 0.0, 1.0);
    vec3 col = mix(red, blue, t);
    col = mix(col, vec3(0.0, 1.0, 0.0), smoothstep(0.3, 0.7, uv.y));
    FragColor = vec4(col, 1.0);
}
""",
    "ternary_chain": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = uv.x > 0.5 ? 1.0 : 0.2;
    float g = uv.y > 0.5 ? 0.8 : 0.1;
    float b = (uv.x + uv.y) > 0.8 ? 1.0 : 0.0;
    FragColor = vec4(r, g, b, 1.0);
}
""",
    "struct_usage": """
#version 430
layout(location = 0) out vec4 FragColor;
struct Light {
    vec3 color;
    float intensity;
};
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    Light l;
    l.color = vec3(uv, 0.5);
    l.intensity = 2.0;
    vec3 col = l.color * l.intensity * 0.5;
    FragColor = vec4(col, 1.0);
}
""",
    "func_calls": """
#version 430
layout(location = 0) out vec4 FragColor;
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float n = noise(uv * 8.0);
    FragColor = vec4(n, n, n, 1.0);
}
""",
    "mat_operations": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    mat2 m = mat2(0.707, -0.707, 0.707, 0.707);
    vec2 rotated = m * (uv - 0.5) + 0.5;
    float d = length(rotated - 0.5);
    vec3 col = vec3(smoothstep(0.3, 0.31, d) - smoothstep(0.35, 0.36, d));
    FragColor = vec4(col, 1.0);
}
""",
    "logical_ops": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    bool inCircle = length(uv - 0.5) < 0.3;
    bool inSquare = abs(uv.x - 0.5) < 0.2 && abs(uv.y - 0.5) < 0.2;
    float r = inCircle && !inSquare ? 1.0 : 0.0;
    float g = inSquare && !inCircle ? 1.0 : 0.0;
    float b = inCircle && inSquare ? 1.0 : 0.0;
    FragColor = vec4(r, g, b, 1.0);
}
""",
    "bit_ops": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    int x = int(uv.x * 255.0);
    int y = int(uv.y * 255.0);
    int z = x ^ y;
    float c = float(z & 0xFF) / 255.0;
    FragColor = vec4(c, c, c, 1.0);
}
""",
    "exp_log": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = exp(uv.x * 2.0 - 1.0) / 3.0;
    float g = log(uv.y * 5.0 + 1.0) / 2.0;
    float b = pow(uv.x, 3.0);
    FragColor = vec4(r, g, b, 1.0);
}
""",
    "constants_and_nans": """
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = max(uv.x, 0.0);
    float g = min(uv.y, 1.0);
    float b = ceil(uv.x * 4.0) / 4.0;
    float a = floor(uv.y * 4.0) / 4.0;
    FragColor = vec4(r, g, b, 1.0);
}
""",
}


def compile_glslpp_glsl(source: str, spv_path: str) -> tuple[bool, str]:
    """Compile GLSL through glslpp: glslpp → SPIR-V → GLSL."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.frag', delete=False, dir=GLSLPP_DIR) as f:
        f.write(source)
        src_path = f.name

    try:
        # glslangValidator → SPIR-V
        r = subprocess.run(
            [GLSLANG, "-V", "-S", "frag", src_path, "-o", spv_path],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode != 0:
            return False, f"glslangValidator: {r.stderr[:200]}"

        # Use dump_shader tool for glslpp compilation
        # Actually, we need to use the Zig tool. Let me use spirv-cross for the reference
        # and the glslpp library via the cross_validate tool.
        # For simplicity, let's use the direct approach:
        # glslangValidator → SPIR-V, then both glslpp and spirv-cross compile SPIR-V → GLSL
        return True, ""
    finally:
        os.unlink(src_path)


def spirv_to_glsl_glslpp(spv_path: str, output_path: str) -> tuple[bool, str]:
    """Convert SPIR-V to GLSL using glslpp (via cross_validate tool)."""
    # We need a small tool that does SPIR-V → GLSL via glslpp
    # For now, use the dump_shader tool
    tool = GLSLPP_DIR / "tools" / "dump_spv.zig"
    # Actually let's just call the library directly — we need a simple CLI wrapper
    # For now, let me build a small tool
    try:
        r = subprocess.run(
            ["zig", "build", "dump-spv", "--", spv_path, output_path.replace(".glsl", ""), "glsl"],
            capture_output=True, text=True, timeout=30,
            cwd=str(GLSLPP_DIR)
        )
        if r.returncode != 0:
            return False, f"glslpp: {r.stderr[:200]}"
        return True, ""
    except Exception as e:
        return False, str(e)


def spirv_to_glsl_spirvcross(spv_path: str) -> tuple[bool, str]:
    """Convert SPIR-V to GLSL using spirv-cross."""
    try:
        r = subprocess.run(
            [SPIRVCROSS, spv_path, "--version", "430", "--glsl-emit-push-constant-as-ubo"],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode == 0:
            return True, r.stdout
        return False, r.stderr[:200]
    except Exception as e:
        return False, str(e)


def render_compare(glsl1_path: str, glsl2_path: str, size: int = 128) -> tuple[bool, int, str]:
    """Compare rendering of two GLSL files using gl_render_compare."""
    if not RENDER_TOOL.exists():
        return False, -1, "gl_render_compare.exe not found"

    try:
        r = subprocess.run(
            [str(RENDER_TOOL), glsl1_path, glsl2_path, str(size), str(size)],
            capture_output=True, text=True, timeout=60
        )
        output = r.stdout + r.stderr

        # Parse results
        max_diff = -1
        diff_pixels = -1
        for line in output.split('\n'):
            if "Max channel diff" in line:
                try:
                    max_diff = int(line.split(':')[-1].strip())
                except:
                    pass
            if "Different pixels" in line:
                try:
                    diff_pixels = int(line.split(':')[0].split('/')[-1].strip().split()[0])
                except:
                    pass

        match = max_diff <= 1 if max_diff >= 0 else False
        return match, max_diff, output
    except Exception as e:
        return False, -1, str(e)


def run_single_shader(name: str, source: str, tmpdir: str) -> dict:
    """Run rendering comparison for a single shader."""
    result = {
        "name": name,
        "glslang_ok": False,
        "glslpp_glsl_ok": False,
        "spirvcross_glsl_ok": False,
        "render_match": None,
        "max_diff": -1,
        "error": ""
    }

    src_path = os.path.join(tmpdir, f"{name}.frag")
    spv_path = os.path.join(tmpdir, f"{name}.spv")
    glslpp_glsl_path = os.path.join(tmpdir, f"{name}_glslpp.glsl")
    spirvcross_glsl_path = os.path.join(tmpdir, f"{name}_spirvcross.glsl")

    with open(src_path, 'w') as f:
        f.write(source)

    # Step 1: glslangValidator → SPIR-V
    r = subprocess.run(
        [GLSLANG, "-V", "-S", "frag", src_path, "-o", spv_path],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode != 0:
        result["error"] = f"glslangValidator: {r.stderr[:200]}"
        return result
    result["glslang_ok"] = True

    # Step 2a: spirv-cross SPIR-V → GLSL (reference)
    ok, glsl_code = spirv_to_glsl_spirvcross(spv_path)
    if not ok:
        result["error"] = f"spirv-cross GLSL: {glsl_code}"
        return result
    result["spirvcross_glsl_ok"] = True
    with open(spirvcross_glsl_path, 'w') as f:
        f.write(glsl_code)

    # Step 2b: glslpp SPIR-V → GLSL
    # We need a CLI wrapper. Let's build a minimal one.
    # Actually, let me check if dump_shader can do this...
    # The dump_shader.zig takes GLSL input, compiles to SPIR-V, then cross-compiles.
    # We need a tool that takes SPIR-V and cross-compiles to GLSL.
    # Let me create a minimal wrapper script.
    
    # For now, let's build the SPIR-V → GLSL tool inline using the glslpp library
    # We'll create a temporary Zig file
    wrapper_path = os.path.join(tmpdir, "spv_to_glsl.zig")
    with open(wrapper_path, 'w') as f:
        f.write("""const std = @import("std");
const glslpp = @import("glslpp");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alloc);
    if (args.len < 3) {
        std.debug.print("Usage: spv_to_glsl <input.spv> <output.glsl>\\n", .{});
        return;
    }
    const spv_data = try std.fs.cwd().readFileAlloc(alloc, args[1], 10 * 1024 * 1024);
    const spirv = std.mem.bytesAsSlice(u32, spv_data);
    const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .version = 430 });
    defer alloc.free(glsl);
    const file = try std.fs.cwd().createFile(args[2], .{});
    defer file.close();
    try file.writeAll(glsl);
}
""")

    # This won't work without the build system... let me take a different approach.
    # Use the existing cross_validate.zig or create a proper build step.
    
    # Actually, the simplest approach: Use the existing dump_shader tool with the 
    # input GLSL file. It compiles GLSL → SPIR-V → all backends.
    # But we need SPIR-V → GLSL only.
    
    # Let me just use the build system's run artifact approach.
    # Better: create a standalone tool in tools/ directory.
    
    result["error"] = "glslpp SPIR-V→GLSL tool not yet built"
    return result


def main():
    parser = argparse.ArgumentParser(description="Rendering comparison for glslpp")
    parser.add_argument("--all", action="store_true", help="Run all rendering tests")
    parser.add_argument("--list", action="store_true", help="List test shaders")
    parser.add_argument("--generate", action="store_true", help="Generate test shader files")
    parser.add_argument("--output-dir", default="tests/render_compare", help="Output directory")
    args = parser.parse_args()

    if args.list:
        for name in sorted(RENDER_TEST_SHADERS.keys()):
            print(f"  {name}")
        return

    if args.generate:
        out_dir = GLSLPP_DIR / args.output_dir
        out_dir.mkdir(parents=True, exist_ok=True)
        for name, source in RENDER_TEST_SHADERS.items():
            path = out_dir / f"{name}.frag"
            with open(path, 'w') as f:
                f.write(source)
            print(f"  Generated {path}")
        print(f"\nGenerated {len(RENDER_TEST_SHADERS)} test shaders in {out_dir}")
        return

    if args.all:
        print("Rendering Comparison: glslpp vs spirv-cross")
        print("=" * 60)
        print(f"GLSLANG: {GLSLANG}")
        print(f"SPIRVCROSS: {SPIRVCROSS}")
        print(f"RENDER_TOOL: {RENDER_TOOL}")
        print(f"Test shaders: {len(RENDER_TEST_SHADERS)}")
        print()

        with tempfile.TemporaryDirectory() as tmpdir:
            for name, source in sorted(RENDER_TEST_SHADERS.items()):
                print(f"  {name}...", end=" ", flush=True)
                result = run_single_shader(name, source, tmpdir)
                if result["render_match"] is True:
                    print(f"MATCH (max_diff={result['max_diff']})")
                elif result["render_match"] is False:
                    print(f"DIFFER (max_diff={result['max_diff']})")
                else:
                    print(f"SKIP ({result['error']})")
        return

    print("Use --all, --list, or --generate")


if __name__ == "__main__":
    main()
