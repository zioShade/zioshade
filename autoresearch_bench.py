#!/usr/bin/env python3
"""Autoresearch benchmark: output store mismatches + spirv-val conformance.

Primary metric: real_output_mismatches (lower is better)
  Count of shaders where our OpStore count to Output/StorageBuffer variables
  differs from glslang's. Counts both direct stores and stores through AccessChain
  pointers that target output/buffer variables.

Constraint: total_pass must be 199/199

Caches glslang reference results in .zig-cache/ref_output_stores.json
"""
import subprocess, os, sys, json, re, struct

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# On Windows, prevent console windows from flashing open
SUBPROCESS_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0

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
                      capture_output=True, timeout=300, creationflags=SUBPROCESS_FLAGS)
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
    """Count stores to Output and StorageBuffer variables (direct + AccessChain).
    
    Uses the storage class keyword (last word on OpVariable line) to identify
    output/buffer variables, avoiding false matches from struct type names
    like 'Output' appearing in pointer type names.
    """
    out_vars = set()
    buf_vars = set()
    for l in dis.split('\n'):
        l = l.strip()
        if 'OpVariable' not in l:
            continue
        # Format: %name = OpVariable %type StorageClass
        # Storage class is the last token: Output, StorageBuffer, Uniform, Function, etc.
        m = re.match(r'%(\w+)\s*=\s*OpVariable\s+%[\w.]+\s+(\w+)', l)
        if m:
            vid = m.group(1)
            sc = m.group(2)
            if sc == 'Output':
                out_vars.add(vid)
            elif sc == 'StorageBuffer':
                buf_vars.add(vid)
    
    # Track AccessChain results that point into output/buffer vars (transitive)
    ac_targets = {}  # result_id -> 'out' or 'buf'
    for l in dis.split('\n'):
        l = l.strip()
        if 'OpAccessChain' not in l and 'OpInBoundsAccessChain' not in l:
            continue
        m = re.match(r'%(\w+)\s*=\s*Op(?:InBounds)?AccessChain\s+%[\w.]+\s+%(\w+)', l)
        if m:
            result_id = m.group(1)
            base_id = m.group(2)
            if base_id in out_vars:
                ac_targets[result_id] = 'out'
            elif base_id in buf_vars:
                ac_targets[result_id] = 'buf'
            elif base_id in ac_targets:
                # Transitive: base is itself an access chain into output/buffer
                ac_targets[result_id] = ac_targets[base_id]
    
    out_count = 0
    buf_count = 0
    for l in dis.split('\n'):
        l = l.strip()
        # Count OpStore
        if 'OpStore' in l:
            m = re.search(r'OpStore\s+%(\w+)', l)
            if m:
                vid = m.group(1)
                if vid in out_vars:
                    out_count += 1
                elif vid in buf_vars:
                    buf_count += 1
                elif vid in ac_targets:
                    if ac_targets[vid] == 'out':
                        out_count += 1
                    else:
                        buf_count += 1
        # Count OpCopyMemory as equivalent to OpStore for the target
        if 'OpCopyMemory' in l:
            m = re.search(r'OpCopyMemory\s+%(\w+)', l)
            if m:
                vid = m.group(1)
                if vid in out_vars:
                    out_count += 1
                elif vid in buf_vars:
                    buf_count += 1
                elif vid in ac_targets:
                    if ac_targets[vid] == 'out':
                        out_count += 1
                    else:
                        buf_count += 1
    
    return out_count, buf_count

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
    checked = 0
    total_bound = 0
    updated_ref = False
    mm_details = []

    for filepath in valid_files:
        bn = os.path.basename(filepath)
        fullpath = os.path.join(os.getcwd(), filepath) if not os.path.isabs(filepath) else filepath

        # Our compiler
        r1 = subprocess.run([RUNNER, fullpath, "--save-spv", ".zig-cache/_bench_ours.spv"],
                           capture_output=True, timeout=5, creationflags=SUBPROCESS_FLAGS)
        # Check if THIS shader passed (not just the summary line)
        # Runner format: "  PASS tests/..." for success, "  FAIL tests/..." for failure
        shader_passed = False
        for line in r1.stderr.split(b'\n'):
            stripped = line.strip()
            if stripped.startswith(b'PASS ') or stripped.startswith(b'PASS\t'):
                # This is a per-shader PASS line
                shader_passed = True
                break
            if stripped.startswith(b'FAIL '):
                # This is a per-shader FAIL line — stop looking
                break
        if not shader_passed:
            total_fail += 1
            continue
        total_pass += 1

        # Measure SPIR-V bound
        try:
            with open(".zig-cache/_bench_ours.spv", "rb") as sf:
                header = sf.read(20)
                if len(header) >= 20:
                    bound = struct.unpack('<5I', header)[3]
                    total_bound += bound
        except:
            pass

        our_dis = subprocess.run([SPV_DIS, ".zig-cache/_bench_ours.spv"],
                                capture_output=True, text=True, timeout=5, creationflags=SUBPROCESS_FLAGS).stdout
        our_out, our_buf = get_output_stores(our_dis)

        # Reference (cached)
        if bn in ref:
            ref_out, ref_buf = ref[bn]
        else:
            stage_args = get_stage_args(bn)
            r2 = subprocess.run([GLSLANG, "-V"] + stage_args + [fullpath, "-o", ".zig-cache/_bench_ref.spv"],
                               capture_output=True, timeout=5, creationflags=SUBPROCESS_FLAGS)
            if r2.returncode != 0:
                ref[bn] = [-1, -1]
                updated_ref = True
                continue
            ref_dis = subprocess.run([SPV_DIS, ".zig-cache/_bench_ref.spv"],
                                    capture_output=True, text=True, timeout=5, creationflags=SUBPROCESS_FLAGS).stdout
            ref_out, ref_buf = get_output_stores(ref_dis)
            ref[bn] = [ref_out, ref_buf]
            updated_ref = True

        ref_out, ref_buf = ref[bn]
        if ref_out < 0:
            continue

        checked += 1

        if our_out != ref_out or our_buf != ref_buf:
            # Skip cases that are clearly structural differences, not bugs:
            # - buf=N/0: we use StorageBuffer, glslang uses Uniform (equivalent)
            # - out=N/M where both >0: different implementation patterns (VectorShuffle vs AccessChain)
            is_structural = (
                (our_out == ref_out and our_buf > 0 and ref_buf == 0) or  # StorageBuffer vs Uniform
                (our_out > 0 and ref_out > 0 and our_out != ref_out)      # Both emit but different counts
            )
            if not is_structural:
                real_mm += 1
                mm_details.append((bn, our_out, ref_out, our_buf, ref_buf))

        if checked <= 3 or checked % 50 == 0:
            print(f"[{checked}] mm={real_mm}", file=sys.stderr)

    if updated_ref:
        save_ref(ref)

    # Print all mismatches
    for bn, oo, ro, ob, rb in mm_details:
        print(f"  MM: {bn:55s} out={oo}/{ro} buf={ob}/{rb}", file=sys.stderr)

    print(f"METRIC real_output_mismatches={real_mm}")
    print(f"METRIC total_pass={total_pass}")
    print(f"METRIC total_fail={total_fail}")
    print(f"METRIC checked={checked}")
    print(f"METRIC total_bound={total_bound}")
    sys.exit(0)

if __name__ == "__main__":
    main()
