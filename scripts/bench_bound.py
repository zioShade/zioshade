#!/usr/bin/env python3
"""Measure total SPIR-V ID bound across all passing shaders."""
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
    valid_files = []
    with open(CACHE) as f:
        for line in f:
            parts = line.strip().split(' ', 1)
            if parts[0] == 'VALID' and len(parts) == 2:
                valid_files.append(parts[1])

    our_total = 0
    ref_total = 0
    count = 0

    our_spv = os.path.join(SPV_DIR, "_bound_our.spv")
    ref_spv = os.path.join(SPV_DIR, "_bound_ref.spv")

    for filepath in valid_files:
        filepath = os.path.join(os.getcwd(), filepath)
        # Our compiler
        result = subprocess.run([RUNNER, filepath, "--save-spv", our_spv],
                              capture_output=True, timeout=5)
        # Runner outputs to stderr
        output = result.stderr.decode('utf-8', errors='replace')
        if "PASS" not in output:
            continue

        try:
            with open(our_spv, 'rb') as f:
                data = f.read(16)
                if len(data) >= 16:
                    bound = struct.unpack('<I', data[12:16])[0]
                    our_total += bound
        except:
            continue

        # glslang reference
        args = [GLSLANG, "-V"] + get_stage_flag(filepath) + [filepath, "-o", ref_spv]
        subprocess.run(args, capture_output=True, timeout=5)
        try:
            with open(ref_spv, 'rb') as f:
                data = f.read(16)
                if len(data) >= 16:
                    bound = struct.unpack('<I', data[12:16])[0]
                    ref_total += bound
                    count += 1
        except:
            pass

        if count <= 5 or count % 50 == 0:
            print(f"[{count}] our={our_total} ref={ref_total}", file=sys.stderr)

    print(f"METRIC our_bound_total={our_total}")
    print(f"METRIC ref_bound_total={ref_total}")
    print(f"METRIC bound_count={count}")
    if ref_total > 0:
        ratio = our_total / ref_total
        print(f"METRIC bound_ratio={ratio:.4f}")

if __name__ == "__main__":
    main()
