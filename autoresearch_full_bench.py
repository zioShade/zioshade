#!/usr/bin/env python3
"""Full-coverage benchmark: all glslang Test/ shaders + spirv-cross + ghostty.

Primary metric: total_pass (higher is better)
Includes ALL shader stages that glslpp supports (frag, vert, comp, geom, tesc, tese).
Skips stages not yet supported (mesh, task, ray tracing).
Skips files with 'Error' in the name (expected-fail tests).
"""

import subprocess, os, json, sys, time

SUBPROCESS_FLAGS = 0x08000000  # CREATE_NO_WINDOW

GLSLANG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "glslang", "Test")
SPIRV_CROSS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "tests", "spirv-cross")
GHOSTTY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "tests", "ghostty")
RUNNER = os.path.join(".zig-cache", "bin", "conformance-runner.exe")
SPIRV_VAL = os.path.join("C:", os.sep, "VulkanSDK", "1.4.341.1", "Bin", "spirv-val.exe")
TMPSPV = os.path.join(".zig-cache", "tmp_bench.spv")

# Stages that glslpp currently supports
SUPPORTED_EXTS = {'.frag', '.vert', '.comp', '.geom', '.tesc', '.tese'}

# Stages NOT yet supported
UNSUPPORTED_EXTS = {'.mesh', '.task', '.rgen', '.rmiss', '.rchit', '.rahit', '.rint', '.rcall'}

CACHE_FILE = ".zig-cache/full_bench_results.json"


def get_glslang_shaders():
    """Get all non-error glslang test files for supported stages."""
    if not os.path.isdir(GLSLANG_DIR):
        print(f"WARNING: glslang Test/ not found at {GLSLANG_DIR}", file=sys.stderr)
        return []
    
    shaders = []
    for f in sorted(os.listdir(GLSLANG_DIR)):
        ext = '.' + f.rsplit('.', 1)[-1] if '.' in f else ''
        fp = os.path.join(GLSLANG_DIR, f)
        if ext in SUPPORTED_EXTS and os.path.isfile(fp) and 'Error' not in f:
            shaders.append(fp)
    return shaders


def get_spirv_cross_shaders():
    """Get all spirv-cross test shaders."""
    if not os.path.isdir(SPIRV_CROSS_DIR):
        print(f"WARNING: spirv-cross tests not found at {SPIRV_CROSS_DIR}", file=sys.stderr)
        return []
    
    shaders = []
    for f in sorted(os.listdir(SPIRV_CROSS_DIR)):
        if f.endswith(('.frag', '.vert', '.comp', '.geom')):
            shaders.append(os.path.join(SPIRV_CROSS_DIR, f))
    return shaders


def get_ghostty_shaders():
    """Get ghostty real-world shaders."""
    if not os.path.isdir(GHOSTTY_DIR):
        return []
    shaders = []
    for f in sorted(os.listdir(GHOSTTY_DIR)):
        if f.endswith(('.f.glsl', '.v.glsl', '.c.glsl')):
            shaders.append(os.path.join(GHOSTTY_DIR, f))
    return shaders


def get_unsupported_count():
    """Count files in unsupported stages."""
    if not os.path.isdir(GLSLANG_DIR):
        return 0
    count = 0
    for f in sorted(os.listdir(GLSLANG_DIR)):
        ext = '.' + f.rsplit('.', 1)[-1] if '.' in f else ''
        fp = os.path.join(GLSLANG_DIR, f)
        if ext in UNSUPPORTED_EXTS and os.path.isfile(fp) and 'Error' not in f:
            count += 1
    return count


def test_shader(full_path):
    """Test a single shader. Returns 'pass', 'compile_fail', 'val_fail', or 'crash'."""
    try:
        r = subprocess.run([RUNNER, full_path, "--save-spv", TMPSPV],
                          capture_output=True, timeout=30, creationflags=SUBPROCESS_FLAGS)
        stderr = r.stderr.decode(errors='replace')
        
        # Check if compiler passed
        passed = any(l.strip().startswith('PASS') for l in stderr.split('\n'))
        if not passed:
            if 'Segmentation fault' in stderr or 'fault' in stderr.lower():
                return 'crash'
            if 'panic' in stderr.lower():
                return 'crash'
            return 'compile_fail'
        
        # Check spirv-val
        r2 = subprocess.run([SPIRV_VAL, TMPSPV], capture_output=True, timeout=10,
                           creationflags=SUBPROCESS_FLAGS)
        if r2.returncode != 0:
            return 'val_fail'
        
        return 'pass'
    except subprocess.TimeoutExpired:
        return 'crash'
    except Exception as e:
        return 'crash'


def main():
    # Collect all shaders
    glslang_shaders = get_glslang_shaders()
    spirv_cross_shaders = get_spirv_cross_shaders()
    ghostty_shaders = get_ghostty_shaders()
    unsupported_count = get_unsupported_count()
    
    total_testable = len(glslang_shaders) + len(spirv_cross_shaders) + len(ghostty_shaders)
    
    print(f"Testing {total_testable} shaders ({len(spirv_cross_shaders)} spirv-cross + {len(glslang_shaders)} glslang + {len(ghostty_shaders)} ghostty)")
    print(f"  (skipping {unsupported_count} unsupported-stage files: mesh/task/ray tracing)")
    
    # Load previous results cache
    prev_results = {}
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE) as f:
                prev_results = json.load(f)
        except:
            pass
    
    # Test all shaders
    results = {}
    counts = {'pass': 0, 'compile_fail': 0, 'val_fail': 0, 'crash': 0}
    failures_by_cat = {'spirv-cross': [], 'glslang': [], 'ghostty': []}
    
    start = time.time()
    all_shaders = [(f, 'spirv-cross') for f in spirv_cross_shaders] + \
                  [(f, 'glslang') for f in glslang_shaders] + \
                  [(f, 'ghostty') for f in ghostty_shaders]
    
    for i, (fp, cat) in enumerate(all_shaders):
        name = os.path.basename(fp)
        
        # Use cached result if file hasn't changed
        mtime = str(os.path.getmtime(fp)) if os.path.exists(fp) else '0'
        cache_key = f"{cat}/{name}"
        if cache_key in prev_results and prev_results[cache_key].get('mtime') == mtime:
            result = prev_results[cache_key]['result']
        else:
            result = test_shader(fp)
            results[cache_key] = {'result': result, 'mtime': mtime}
        
        if result not in counts:
            counts[result] = 0
        counts[result] += 1
        
        if result != 'pass':
            failures_by_cat[cat].append(name)
        
        if (i + 1) % 50 == 0 or i == len(all_shaders) - 1:
            elapsed = time.time() - start
            rate = (i + 1) / elapsed if elapsed > 0 else 0
            print(f"  [{i+1}/{len(all_shaders)}] {counts['pass']} pass, {counts['val_fail']} val_fail, {counts['compile_fail']} compile_fail, {counts['crash']} crash ({rate:.0f}/s)")
    
    # Save results cache
    with open(CACHE_FILE, 'w') as f:
        json.dump(results if results else prev_results, f)
    
    # Summary
    total_pass = counts['pass']
    total = sum(counts.values())
    
    print()
    print(f"=== SUMMARY ===")
    print(f"spirv-cross: {len(spirv_cross_shaders) - len(failures_by_cat['spirv-cross'])}/{len(spirv_cross_shaders)}")
    print(f"glslang:     {len(glslang_shaders) - len(failures_by_cat['glslang'])}/{len(glslang_shaders)}")
    print(f"ghostty:     {len(ghostty_shaders) - len(failures_by_cat['ghostty'])}/{len(ghostty_shaders)}")
    print(f"TOTAL:       {total_pass}/{total} ({100*total_pass/total:.1f}%)" if total > 0 else "TOTAL: 0/0")
    print(f"UNSUPPORTED: {unsupported_count} (mesh/task/ray tracing)")
    
    if counts['val_fail'] > 0:
        print(f"\nspirv-val failures ({counts['val_fail']}):")
        for cat in ['spirv-cross', 'glslang', 'ghostty']:
            cat_val = [n for n in failures_by_cat[cat] if n not in []]  # all are val_fail or compile_fail
            if cat_val:
                print(f"  [{cat}]: {len(cat_val)}")
                for n in cat_val[:20]:
                    print(f"    {n}")
                if len(cat_val) > 20:
                    print(f"    ... and {len(cat_val) - 20} more")
    
    if counts['compile_fail'] > 0:
        print(f"\nCompile failures ({counts['compile_fail']}):")
        for cat in ['spirv-cross', 'glslang', 'ghostty']:
            if failures_by_cat[cat]:
                for n in failures_by_cat[cat][:10]:
                    print(f"  {n}")
                if len(failures_by_cat[cat]) > 10:
                    print(f"  ... and {len(failures_by_cat[cat]) - 10} more")
    
    # Output metrics for autoresearch
    print(f"\nMETRIC total_pass={total_pass}")
    print(f"METRIC total_compile_fail={counts['compile_fail']}")
    print(f"METRIC total_val_fail={counts['val_fail']}")
    print(f"METRIC total_crash={counts['crash']}")
    print(f"METRIC total_shaders={total}")
    print(f"METRIC total_unsupported={unsupported_count}")
    print(f"METRIC sc_pass={len(spirv_cross_shaders) - len(failures_by_cat['spirv-cross'])}")
    print(f"METRIC gl_pass={len(glslang_shaders) - len(failures_by_cat['glslang'])}")
    print(f"METRIC ghostty_pass={len(ghostty_shaders) - len(failures_by_cat['ghostty'])}")


if __name__ == '__main__':
    main()
