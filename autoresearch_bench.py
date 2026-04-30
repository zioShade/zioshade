#!/usr/bin/env python3
"""Autoresearch benchmark: REAL output store mismatches + spirv-val conformance.

Primary metric: real_output_mismatches (lower is better)
  Count of shaders where our OpStore count to Output/StorageBuffer variables
  differs from glslang's, EXCLUDING false positives from gl_PerVertex wrapping.
  
Constraint: total_pass must be 199/199

Caches glslang reference results in .zig-cache/ref_output_stores.json
"""
import subprocess, os, sys, json, re

os.chdir(os.path.dirname(os.path.abspath(__file__)))

RUNNER = os.path.join(os.getcwd(), ".zig-cache", "bin", "conformance-runner.exe")
GLSLANG = "C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPV_DIS = "C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe"
ZIG = "C:/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe"
CACHE = ".zig-cache/ref_classification.txt"
REF_CACHE = ".zig-cache/ref_output_stores.json"

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

def load_ref():
    if os.path.exists(REF_CACHE):
        with open(REF_CACHE) as f:
            return json.load(f)
    return {}

def save_ref(data):
    with open(REF_CACHE, 'w') as f:
        json.dump(data, f)

def get_output_stores(dis):
    """Get count of stores to Output and StorageBuffer variables."""
    out_vars = set()
    buf_vars = set()
    for l in dis.split('\n'):
        l = l.strip()
        if 'OpVariable' in l:
            m = re.match(r'%(\w+)\s*=', l)
            if m:
                vid = m.group(1)
                if 'Output' in l: out_vars.add(vid)
                elif 'StorageBuffer' in l: buf_vars.add(vid)
    
    out_count = 0
    buf_count = 0
    for l in dis.split('\n'):
        l = l.strip()
        if 'OpStore' not in l: continue
        m = re.search(r'OpStore\s+%(\w+)', l)
        if m:
            vid = m.group(1)
            if vid in out_vars: out_count += 1
            if vid in buf_vars: buf_count += 1
    
    return out_count, buf_count

def has_gl_pervertex(dis):
    """Check if reference uses gl_PerVertex block wrapping (anonymous %_ output var)."""
    for l in dis.split('\n'):
        l = l.strip()
        if 'OpVariable' in l and 'Output' in l:
            if re.match(r'%_\s*=', l):
                return True
    return False

def main():
    if not build():
        print("METRIC real_output_mismatches=999")
        return

    ref = load_ref()

    valid_files = []
    with open(CACHE) as f:
        for line in f:
            parts = line.strip().split(' ', 1)
            if parts[0] == 'VALID' and len(parts) == 2:
                valid_files.append(parts[1])

    total_pass = 0
    total_fail = 0
    real_mm = 0
    fp_mm = 0
    checked = 0
    updated_ref = False

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

        our_dis = subprocess.run([SPV_DIS, ".zig-cache/_bench_ours.spv"],
                                capture_output=True, text=True, timeout=5).stdout
        our_out, our_buf = get_output_stores(our_dis)

        # Reference (cached)
        if bn in ref:
            ref_out, ref_buf, ref_pervertex = ref[bn]
        else:
            stage_args = get_stage_args(bn)
            r2 = subprocess.run([GLSLANG, "-V"] + stage_args + [fullpath, "-o", ".zig-cache/_bench_ref.spv"],
                               capture_output=True, timeout=5)
            if r2.returncode != 0:
                ref[bn] = [-1, -1, False]
                updated_ref = True
                continue
            ref_dis = subprocess.run([SPV_DIS, ".zig-cache/_bench_ref.spv"],
                                    capture_output=True, text=True, timeout=5).stdout
            ref_out, ref_buf = get_output_stores(ref_dis)
            ref_pervertex = has_gl_pervertex(ref_dis)
            ref[bn] = [ref_out, ref_buf, ref_pervertex]
            updated_ref = True

        ref_out, ref_buf, ref_pervertex = ref[bn]
        if ref_out < 0:
            continue

        checked += 1

        if our_out != ref_out or our_buf != ref_buf:
            # Check if it's a false positive (gl_PerVertex wrapping)
            is_fp = ref_pervertex and our_out > ref_out and our_buf == ref_buf
            
            if is_fp:
                fp_mm += 1
            else:
                real_mm += 1
                if real_mm <= 15:
                    print(f"  MM: {bn:55s} out={our_out}/{ref_out} buf={our_buf}/{ref_buf}", file=sys.stderr)

        if checked <= 3 or checked % 50 == 0:
            print(f"[{checked}] real_mm={real_mm} fp={fp_mm}", file=sys.stderr)

    if updated_ref:
        save_ref(ref)

    print(f"METRIC real_output_mismatches={real_mm}")
    print(f"METRIC total_pass={total_pass}")
    print(f"METRIC total_fail={total_fail}")
    print(f"METRIC false_positives={fp_mm}")
    print(f"METRIC checked={checked}")
    sys.exit(0)

if __name__ == "__main__":
    main()
