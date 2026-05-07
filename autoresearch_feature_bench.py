#!/usr/bin/env python3
"""Autoresearch benchmark: feature coverage across glslang + spirv-cross test suites.

Primary metric: total_pass (higher is better)
  Count of shaders that compile and pass spirv-val across BOTH the spirv-cross 
  suite (210 shaders) AND the glslang Test suite (~356 shaders).

Constraint: existing 210/210 spirv-cross must not regress.

Also tracks: compile_fail, val_fail, crash count.
"""
import subprocess, os, sys, json, time

os.chdir(os.path.dirname(os.path.abspath(__file__)))

SUBPROCESS_FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0

RUNNER = os.path.join(os.getcwd(), ".zig-cache", "bin", "conformance-runner.exe")
GLSLANG = "C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe"
SPIRV_VAL = "C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe"
ZIG = "C:/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe"
TMPSPV = os.path.join(os.getcwd(), ".zig-cache", "_feature_check.spv")

# Cache for glslang pass/fail
GLSLANG_CACHE = ".zig-cache/glslang_pass_list.json"

def build():
    # Skip build if binary already exists (assume caller built it)
    if os.path.exists(RUNNER):
        return True
    print("Building...", file=sys.stderr)
    os.makedirs(".zig-cache/bin", exist_ok=True)
    r = subprocess.run([ZIG, "build-exe", "-OReleaseSafe",
                       "--dep", "glslpp", "-Mroot=tests/runner.zig", "-Mglslpp=src/root.zig",
                       "--cache-dir", ".zig-cache",
                       "-femit-bin=" + RUNNER],
                      capture_output=True, timeout=300, creationflags=SUBPROCESS_FLAGS)
    if not os.path.exists(RUNNER):
        print("ERROR: build failed", file=sys.stderr)
        print(r.stderr.decode(errors='replace'), file=sys.stderr)
        return False
    return True

def get_glslang_pass_list():
    """Get list of glslang Test/ shaders that glslang -V can compile."""
    if os.path.exists(GLSLANG_CACHE):
        with open(GLSLANG_CACHE) as f:
            return json.load(f)
    
    glslang_test_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 
                                     "..", "glslang", "Test")
    if not os.path.isdir(glslang_test_dir):
        print(f"WARNING: glslang Test/ not found at {glslang_test_dir}", file=sys.stderr)
        return []
    
    all_shaders = []
    for ext in ['.frag', '.vert', '.comp', '.geom', '.tesc', '.tese']:
        for f in sorted(os.listdir(glslang_test_dir)):
            fp = os.path.join(glslang_test_dir, f)
            if f.endswith(ext) and os.path.isfile(fp):
                all_shaders.append(fp)
    
    pass_list = []
    for fp in all_shaders:
        r = subprocess.run([GLSLANG, "-V", fp], capture_output=True, timeout=10,
                          creationflags=SUBPROCESS_FLAGS)
        if r.returncode == 0:
            pass_list.append(fp)
    
    with open(GLSLANG_CACHE, 'w') as f:
        json.dump(pass_list, f)
    
    return pass_list

def get_spirv_cross_shaders():
    """Get the 210 shaders we currently test."""
    cache_file = ".zig-cache/ref_classification.txt"
    if not os.path.exists(cache_file):
        print("WARNING: ref_classification.txt not found", file=sys.stderr)
        return []
    
    shaders = []
    with open(cache_file) as f:
        for line in f:
            parts = line.strip().split(' ', 1)
            if len(parts) > 1 and parts[0] == 'VALID':
                shaders.append(parts[1])
    return shaders

def test_shader(full_path):
    """Test a single shader. Returns 'pass', 'compile_fail', 'val_fail', or 'crash'."""
    try:
        r = subprocess.run([RUNNER, full_path, "--save-spv", TMPSPV],
                          capture_output=True, timeout=15, creationflags=SUBPROCESS_FLAGS)
        stderr = r.stderr.decode(errors='replace')
        
        # Check if compiler passed
        passed = any(l.strip().startswith('PASS') for l in stderr.split('\n'))
        if not passed:
            if 'Segmentation fault' in stderr or 'fault' in stderr.lower():
                return 'crash'
            return 'compile_fail'
        
        # Check spirv-val
        r2 = subprocess.run([SPIRV_VAL, TMPSPV], capture_output=True, timeout=10,
                           creationflags=SUBPROCESS_FLAGS)
        if r2.returncode != 0:
            val_out = r2.stdout.decode(errors='replace').strip()
            val_err = r2.stderr.decode(errors='replace').strip()
            return 'val_fail'
        
        return 'pass'
    except subprocess.TimeoutExpired:
        return 'crash'
    except Exception as e:
        return 'crash'

def main():
    if not build():
        print("METRIC total_pass=0")
        print("METRIC total_compile_fail=0")
        print("METRIC total_val_fail=0")
        print("METRIC total_crash=0")
        print("METRIC total_shaders=0")
        return
    
    # Collect all test shaders
    sc_shaders = get_spirv_cross_shaders()
    gl_shaders = get_glslang_pass_list()
    
    # Deduplicate (some shaders might appear in both)
    all_paths = set()
    all_shaders = []
    
    for s in sc_shaders:
        full = os.path.join(os.getcwd(), s) if not os.path.isabs(s) else s
        if full not in all_paths:
            all_paths.add(full)
            all_shaders.append(('spirv-cross', s, full))
    
    for s in gl_shaders:
        if s not in all_paths:
            all_paths.add(s)
            all_shaders.append(('glslang', os.path.basename(s), s))
    
    print(f"Testing {len(all_shaders)} shaders ({len(sc_shaders)} spirv-cross + {len(gl_shaders)} glslang)...", file=sys.stderr)
    
    # Test all shaders
    results = {'pass': 0, 'compile_fail': 0, 'val_fail': 0, 'crash': 0}
    sc_pass = 0
    gl_pass = 0
    sc_total = 0
    gl_total = 0
    
    # Track failures for summary
    val_fail_list = []
    compile_fail_list = []
    
    for suite, name, full_path in all_shaders:
        if suite == 'spirv-cross':
            sc_total += 1
        else:
            gl_total += 1
        
        result = test_shader(full_path)
        results[result] += 1
        
        if result == 'pass':
            if suite == 'spirv-cross':
                sc_pass += 1
            else:
                gl_pass += 1
        elif result == 'val_fail':
            val_fail_list.append(name)
        elif result == 'compile_fail':
            compile_fail_list.append(name)
    
    total = len(all_shaders)
    
    # Output metrics
    print(f"METRIC total_pass={results['pass']}")
    print(f"METRIC total_compile_fail={results['compile_fail']}")
    print(f"METRIC total_val_fail={results['val_fail']}")
    print(f"METRIC total_crash={results['crash']}")
    print(f"METRIC total_shaders={total}")
    print(f"METRIC sc_pass={sc_pass}")
    print(f"METRIC gl_pass={gl_pass}")
    
    print(f"\n=== SUMMARY ===", file=sys.stderr)
    print(f"spirv-cross: {sc_pass}/{sc_total} ({sc_pass/sc_total*100:.1f}%)" if sc_total else "spirv-cross: N/A", file=sys.stderr)
    print(f"glslang:     {gl_pass}/{gl_total} ({gl_pass/gl_total*100:.1f}%)" if gl_total else "glslang:     N/A", file=sys.stderr)
    print(f"TOTAL:       {results['pass']}/{total} ({results['pass']/total*100:.1f}%)", file=sys.stderr)
    
    if val_fail_list:
        print(f"\nspirv-val failures ({len(val_fail_list)}):", file=sys.stderr)
        for name in val_fail_list:
            print(f"  {name}", file=sys.stderr)
    
    if compile_fail_list:
        print(f"\nCompile failures ({len(compile_fail_list)}):", file=sys.stderr)
        for name in compile_fail_list[:10]:
            print(f"  {name}", file=sys.stderr)

if __name__ == '__main__':
    main()
