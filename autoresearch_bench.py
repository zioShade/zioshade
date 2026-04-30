#!/usr/bin/env python3
"""Autoresearch benchmark: store mismatch count + spirv-val conformance.

Primary metric: store_mismatches (lower is better)
Constraint: total_pass must be 199/199

Caches glslang reference results in .zig-cache/ref_stores/
"""
import subprocess, os, sys, struct, json

os.chdir(os.path.dirname(os.path.abspath(__file__)))

RUNNER = os.path.join(os.getcwd(), ".zig-cache", "bin", "conformance-runner.exe")
GLSLANG = "C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS = "C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
SPV_VAL = "C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe"
ZIG = "C:/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe"
CACHE = ".zig-cache/ref_classification.txt"
STORE_CACHE = ".zig-cache/ref_stores.json"

def get_stage_args(bn):
    if bn.endswith('.v.glsl'): return ['-S', 'vert']
    if bn.endswith('.c.glsl'): return ['-S', 'comp']
    return []

def build():
    print("Building...", file=sys.stderr)
    os.makedirs(".zig-cache/bin", exist_ok=True)
    r = subprocess.run([ZIG, "build-exe", "-OReleaseSafe",
                       "--dep", "glslpp", "-Mroot=tests/runner.zig", "-Mglslpp=src/root.zig",
                       "--cache-dir", ".zig-cache",
                       "-femit-bin=" + RUNNER],
                      capture_output=True, timeout=120)
    if not os.path.exists(RUNNER):
        print("ERROR: build failed", file=sys.stderr)
        return False
    return True

def load_ref_stores():
    """Load cached glslang store counts."""
    if os.path.exists(STORE_CACHE):
        with open(STORE_CACHE) as f:
            return json.load(f)
    return {}

def save_ref_stores(data):
    with open(STORE_CACHE, 'w') as f:
        json.dump(data, f, indent=2)

def count_stores(spv_path):
    """Count OpStore instructions in disassembled SPIR-V."""
    r = subprocess.run([SPV_DIS, spv_path], capture_output=True, text=True, timeout=5)
    return r.stdout.count('OpStore')

def main():
    if not build():
        print("METRIC store_mismatches=999")
        return

    ref_stores = load_ref_stores()

    # Read classification
    valid_files = []
    with open(CACHE) as f:
        for line in f:
            parts = line.strip().split(' ', 1)
            if parts[0] == 'VALID' and len(parts) == 2:
                valid_files.append(parts[1])

    total_pass = 0
    total_fail = 0
    mismatches = 0
    both_valid = 0
    new_ref_data = {}

    for filepath in valid_files:
        bn = os.path.basename(filepath)
        fullpath = os.path.join(os.getcwd(), filepath) if not os.path.isabs(filepath) else filepath

        # Our compiler
        r1 = subprocess.run([RUNNER, fullpath, "--save-spv", ".zig-cache/_bench_ours.spv"],
                           capture_output=True, timeout=5)
        if b"PASS" not in r1.stderr:
            total_fail += 1
            continue
        total_pass += 1

        # glslang - use cached store count if available
        if bn in ref_stores:
            ref_count = ref_stores[bn]
        else:
            stage_args = get_stage_args(bn)
            r2 = subprocess.run([GLSLANG, "-V"] + stage_args + [fullpath, "-o", ".zig-cache/_bench_ref.spv"],
                               capture_output=True, timeout=5)
            if r2.returncode != 0:
                new_ref_data[bn] = -1  # glslang can't compile
                continue
            ref_count = count_stores(".zig-cache/_bench_ref.spv")
            new_ref_data[bn] = ref_count

        if ref_count < 0:
            continue

        both_valid += 1
        our_count = count_stores(".zig-cache/_bench_ours.spv")

        if our_count != ref_count:
            mismatches += 1
            if mismatches <= 10:
                print(f"  MM: {bn:55s} our={our_count:3d} ref={ref_count:3d}", file=sys.stderr)

        if both_valid <= 3 or both_valid % 50 == 0:
            print(f"[{both_valid}] mm={mismatches}", file=sys.stderr)

    # Update cache with any new entries
    if new_ref_data:
        ref_stores.update(new_ref_data)
        save_ref_stores(ref_stores)

    print(f"METRIC store_mismatches={mismatches}")
    print(f"METRIC total_pass={total_pass}")
    print(f"METRIC total_fail={total_fail}")
    print(f"METRIC both_valid={both_valid}")

if __name__ == "__main__":
    main()
