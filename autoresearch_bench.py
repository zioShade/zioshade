#!/usr/bin/env python3
"""Autoresearch benchmark: total SPIR-V ID bound across all passing shaders."""
import struct, subprocess, sys, os

os.chdir(os.path.dirname(os.path.abspath(__file__)))

RUNNER = os.path.join(os.getcwd(), ".zig-cache", "bin", "conformance-runner.exe")
CACHE = os.path.join(os.getcwd(), ".zig-cache", "ref_classification.txt")
GLSLANG = "C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIR = os.path.join(os.getcwd(), ".zig-cache")

def get_stage_flag(path):
    bn = os.path.basename(path)
    if bn.endswith('.f.glsl'): return ['-S', 'frag']
    if bn.endswith('.v.glsl'): return ['-S', 'vert']
    if bn.endswith('.c.glsl'): return ['-S', 'comp']
    return []

def main():
    # Build runner
    print("Building...", file=sys.stderr)
    os.makedirs(os.path.join(SPV_DIR, "bin"), exist_ok=True)
    if not os.path.exists(RUNNER):
        subprocess.run([
            "zig", "build-exe", "-OReleaseSafe",
            "--dep", "glslpp", "-Mroot=tests/runner.zig", "-Mglslpp=src/root.zig",
            "--cache-dir", ".zig-cache",
            "-femit-bin=" + RUNNER
        ], capture_output=True, timeout=120)
    if not os.path.exists(RUNNER):
        print("ERROR: no runner", file=sys.stderr)
        print("METRIC our_bound_total=999999")
        return

    valid_files = []
    with open(CACHE) as f:
        for line in f:
            parts = line.strip().split(' ', 1)
            if parts[0] == 'VALID' and len(parts) == 2:
                valid_files.append(parts[1])

    our_total = 0
    ref_total = 0
    count = 0
    pass_count = 0
    fail_count = 0

    our_spv = os.path.join(SPV_DIR, "_bench.spv")

    for filepath in valid_files:
        fullpath = os.path.join(os.getcwd(), filepath) if not os.path.isabs(filepath) else filepath

        # Our compiler - just compile, no save-spv needed for pass check
        result = subprocess.run([RUNNER, fullpath, "--save-spv", our_spv],
                              capture_output=True, timeout=5)
        output = result.stderr.decode('utf-8', errors='replace')

        if "PASS" not in output:
            fail_count += 1
            continue

        pass_count += 1

        # Read bound from our SPIR-V
        try:
            with open(our_spv, 'rb') as f:
                data = f.read(16)
                if len(data) >= 16:
                    bound = struct.unpack('<I', data[12:16])[0]
                    our_total += bound
        except:
            pass

        count += 1

        if count <= 5 or count % 50 == 0:
            print(f"[{count}] our_total={our_total}", file=sys.stderr)

    print(f"METRIC our_bound_total={our_total}")
    print(f"METRIC total_pass={pass_count}")
    print(f"METRIC total_fail={fail_count}")
    print(f"METRIC bound_count={count}")
    sys.exit(0)

if __name__ == "__main__":
    main()
