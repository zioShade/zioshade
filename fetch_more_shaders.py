#!/usr/bin/env python3
"""
Fetch additional GLSL shader test suites from GitHub for testing glslpp.
Clones (shallow) or downloads shader files from known public repos.
"""

import os
import subprocess
import sys
import shutil
import tempfile
import struct
import time
import urllib.request
import json
import zipfile
import io

GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

GLSLPP_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.zig-cache', 'bin', 'conformance-runner.exe')
SPIRV_VAL = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe'
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FETCH_DIR = os.path.join(BASE_DIR, '.shader_fetch_cache')


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=kw.pop('timeout', 120), **kw)


def download_zip(url):
    """Download a zip from a URL and return the ZipFile object."""
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
    return zipfile.ZipFile(io.BytesIO(data))


def get_bound(path):
    with open(path, 'rb') as f:
        data = f.read(20)
    if len(data) < 20:
        return None
    return struct.unpack('<5I', data)[3]


def test_shader(shader_path):
    """Compile a single shader with glslpp and validate."""
    spv_path = os.path.join(os.environ.get('TEMP', '/tmp'), f'glslpp_extra_test.spv')
    
    result = run([GLSLPP_RUNNER, shader_path, '--save-spv', spv_path], timeout=15)
    if not os.path.exists(spv_path):
        stdout = result.stdout + result.stderr
        if 'SKIP' in stdout:
            return 'skip', None
        # Extract error
        for line in stdout.split('\n'):
            if 'COMPILE' in line or 'error' in line.lower():
                return 'compile_fail', line[:120]
        return 'compile_fail', stdout[:120]
    
    val = run([SPIRV_VAL, spv_path], timeout=10)
    if val.returncode != 0:
        err = val.stderr.strip().split('\n')[0][:120]
        return 'val_fail', err
    
    bound = get_bound(spv_path)
    return 'pass', bound


def fetch_github_tree(repo, path_prefix="", branch="main"):
    """Fetch file listing from a GitHub repo using the Git Trees API."""
    api_url = f"https://api.github.com/repos/{repo}/git/trees/{branch}?recursive=1"
    req = urllib.request.Request(api_url, headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/vnd.github.v3+json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except Exception as e:
        print(f"  {RED}API error for {repo}: {e}{RESET}")
        return []
    
    files = []
    for entry in data.get('tree', []):
        p = entry.get('path', '')
        if path_prefix and not p.startswith(path_prefix):
            continue
        ext = os.path.splitext(p)[1]
        if ext in ('.frag', '.vert', '.comp', '.glsl'):
            files.append(p)
    return files


def download_github_file(repo, path, branch="main"):
    """Download a single file from GitHub raw."""
    url = f"https://raw.githubusercontent.com/{repo}/{branch}/{path}"
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read().decode('utf-8', errors='replace')
    except:
        return None


def fetch_and_test_source(name, repo, path_prefix, branch="main", max_shaders=100):
    """Fetch shaders from a GitHub repo and test them."""
    print(f"\n{BLUE}{'='*60}{RESET}")
    print(f"{BLUE}  {name}{RESET}")
    print(f"{BLUE}{'='*60}")
    
    local_dir = os.path.join(FETCH_DIR, name)
    os.makedirs(local_dir, exist_ok=True)
    
    # Get file list
    print(f"  Fetching file list from {repo}...")
    files = fetch_github_tree(repo, path_prefix, branch)
    
    if not files:
        print(f"  {YELLOW}No shader files found{RESET}")
        return []
    
    print(f"  Found {len(files)} shader files, testing up to {max_shaders}...")
    
    results = []
    tested = 0
    for fpath in files:
        if tested >= max_shaders:
            break
        
        fname = os.path.basename(fpath)
        local_path = os.path.join(local_dir, fname.replace('/', '_'))
        
        # Download if not cached
        if not os.path.exists(local_path):
            content = download_github_file(repo, fpath, branch)
            if content is None:
                continue
            with open(local_path, 'w', encoding='utf-8') as f:
                f.write(content)
            time.sleep(0.1)  # Rate limit
        
        # Test
        status, detail = test_shader(local_path)
        results.append({'name': fname, 'path': local_path, 'status': status, 'detail': detail})
        
        if status == 'pass':
            print(f"    {GREEN}PASS{RESET} {fname} bound={detail}")
        elif status == 'skip':
            pass  # silent
        elif status == 'compile_fail':
            print(f"    {RED}COMPILE FAIL{RESET} {fname}: {(detail or '')[:80]}")
        elif status == 'val_fail':
            print(f"    {RED}VAL FAIL{RESET} {fname}: {(detail or '')[:80]}")
        
        tested += 1
    
    return results


def fetch_local_dir(name, dir_path, max_shaders=100):
    """Test shaders from a local directory."""
    print(f"\n{BLUE}{'='*60}{RESET}")
    print(f"{BLUE}  {name} (local){RESET}")
    print(f"{BLUE}{'='*60}")
    
    results = []
    tested = 0
    
    for root, dirs, files in os.walk(dir_path):
        for fname in sorted(files):
            ext = os.path.splitext(fname)[1]
            if ext not in ('.frag', '.vert', '.comp', '.glsl'):
                continue
            if tested >= max_shaders:
                break
            
            # Skip known error/invalid test files
            if '.error.' in fname or 'link.' in fname:
                continue
            
            local_path = os.path.join(root, fname)
            status, detail = test_shader(local_path)
            results.append({'name': fname, 'path': local_path, 'status': status, 'detail': detail})
            
            if status == 'pass':
                print(f"    {GREEN}PASS{RESET} {fname} bound={detail}")
            elif status == 'compile_fail':
                print(f"    {RED}COMPILE FAIL{RESET} {fname}: {(detail or '')[:80]}")
            elif status == 'val_fail':
                print(f"    {RED}VAL FAIL{RESET} {fname}: {(detail or '')[:80]}")
            
            tested += 1
    
    return results


def main():
    if not os.path.exists(GLSLPP_RUNNER):
        print(f"{RED}glslpp runner not found at {GLSLPP_RUNNER}{RESET}")
        sys.exit(1)
    
    os.makedirs(FETCH_DIR, exist_ok=True)
    
    all_results = {}
    
    # ---- Source 1: glslang Test suite (master branch) ----
    # This is the reference GLSL compiler's own test shaders
    results = fetch_and_test_source(
        "glslang-tests",
        "KhronosGroup/glslang",
        "Test",
        branch="main",
        max_shaders=200,
    )
    all_results['glslang-tests'] = results
    
    # ---- Source 2: SPIRV-Cross test shaders ----
    # Cross-compiler test suite
    results = fetch_and_test_source(
        "spirv-cross-tests",
        "KhronosGroup/SPIRV-Cross",
        "reference",
        branch="main",
        max_shaders=100,
    )
    all_results['spirv-cross-tests'] = results
    
    # ---- Source 3: Amber (Vulkan conformance) ----
    results = fetch_and_test_source(
        "amber-tests",
        "google/amber",
        "tests/cases",
        branch="main",
        max_shaders=50,
    )
    all_results['amber-tests'] = results
    
    # ---- Source 4:Existing test suites we haven't tested individually ----
    for suite_name, suite_dir in [("glslang-430", "tests/glslang-430"), ("spirv-cross", "tests/spirv-cross"), ("ghostty", "tests/ghostty")]:
        full_dir = os.path.join(BASE_DIR, suite_dir)
        if os.path.exists(full_dir):
            results = fetch_local_dir(suite_name, full_dir, max_shaders=500)
            all_results[suite_name] = results
    
    # ---- Source 5: More glslang tests from specific subdirectories ----
    for subdir in ["Test/baseResults", "Test/hlsl"]:
        results = fetch_and_test_source(
            f"glslang-{os.path.basename(subdir)}",
            "KhronosGroup/glslang",
            subdir,
            branch="main",
            max_shaders=100,
        )
        all_results[f"glslang-{os.path.basename(subdir)}"] = results
    
    # ---- GRAND SUMMARY ----
    print(f"\n{BLUE}{'='*70}{RESET}")
    print(f"{BLUE}  GRAND SUMMARY{RESET}")
    print(f"{BLUE}{'='*70}{RESET}")
    
    grand_pass = 0
    grand_fail = 0
    grand_skip = 0
    grand_compile_fail = 0
    failures_by_source = {}
    
    for source, results in all_results.items():
        passed = sum(1 for r in results if r['status'] == 'pass')
        failed = sum(1 for r in results if r['status'] == 'val_fail')
        compile_fails = sum(1 for r in results if r['status'] == 'compile_fail')
        skipped = sum(1 for r in results if r['status'] == 'skip')
        total = len(results)
        bound_sum = sum(r['detail'] for r in results if r['status'] == 'pass' and r['detail'])
        
        grand_pass += passed
        grand_fail += failed
        grand_skip += skipped
        grand_compile_fail += compile_fails
        
        status = f"{GREEN}{passed}/{total} PASS" if passed == total else f"{YELLOW}{passed}/{total} PASS, {failed+compile_fails} fail"
        print(f"  {source:30s} {status}{RESET}  bound_sum={bound_sum}")
        
        if failed + compile_fails > 0:
            failures_by_source[source] = [r for r in results if r['status'] in ('val_fail', 'compile_fail')]
    
    grand_total = grand_pass + grand_fail + grand_compile_fail + grand_skip
    print(f"\n  {'TOTAL':30s} {grand_pass}/{grand_total} PASS")
    print(f"  {'':30s} {grand_compile_fail} compile failures")
    print(f"  {'':30s} {grand_fail} spirv-val failures")
    print(f"  {'':30s} {grand_skip} skipped")
    
    if failures_by_source:
        print(f"\n{RED}ALL FAILURES (for investigation):{RESET}")
        for source, failures in failures_by_source.items():
            print(f"\n  {source}:")
            for r in failures[:10]:  # Show first 10 per source
                print(f"    {RED}X{RESET} {r['name']}: {(r['detail'] or '')[:80]}")
            if len(failures) > 10:
                print(f"    ... and {len(failures)-10} more")
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
