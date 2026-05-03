#!/usr/bin/env python3
"""
Test glslpp against wintty's shadertoy and built-in shaders.
Compares with glslang output and validates with spirv-val.
"""

import subprocess
import os
import sys
import struct
import tempfile
import shutil

# Paths
GLSLPP_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.zig-cache', 'bin', 'conformance-runner.exe')
WINTTY_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'wintty')
SPIRV_VAL = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe'
SPIRV_DIS = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-dis.exe'
SPIRV_OPT = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-opt.exe'

# Colors for output
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

def compile_glslang(source, stage, output_path):
    """Compile GLSL to SPIR-V using glslang (via the wintty pkg)."""
    # Write source to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.glsl', delete=False, encoding='utf-8') as f:
        f.write(source)
        temp_path = f.name
    
    try:
        stage_flag = {
            'vertex': '-S vert',
            'fragment': '-S frag',
            'compute': '-S comp',
        }.get(stage, '-S frag')
        
        result = subprocess.run(
            ['glslangValidator', stage_flag, '-V', '--target-env', 'vulkan1.2', '-o', output_path, temp_path],
            capture_output=True, text=True, timeout=10
        )
        return result.returncode == 0, result.stdout + result.stderr
    except FileNotFoundError:
        return None, "glslangValidator not found on PATH"
    finally:
        os.unlink(temp_path)

def compile_glslpp(source, stage, output_path):
    """Compile GLSL to SPIR-V using glslpp runner."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.glsl', delete=False, encoding='utf-8') as f:
        f.write(source)
        temp_path = f.name
    
    try:
        result = subprocess.run(
            [GLSLPP_RUNNER, temp_path, '--save-spv', output_path],
            capture_output=True, text=True, timeout=10
        )
        # Check if SPIR-V file was actually created
        if os.path.exists(output_path):
            return True, result.stdout + result.stderr
        else:
            return False, result.stdout + result.stderr
    except Exception as e:
        return False, str(e)
    finally:
        os.unlink(temp_path)

def validate_spv(path):
    """Run spirv-val on a SPIR-V binary."""
    result = subprocess.run(
        [SPIRV_VAL, path],
        capture_output=True, text=True, timeout=10
    )
    return result.returncode == 0, result.stdout + result.stderr

def disassemble_spv(path):
    """Disassemble a SPIR-V binary."""
    result = subprocess.run(
        [SPIRV_DIS, path],
        capture_output=True, text=True, timeout=10
    )
    return result.stdout

def get_bound(path):
    """Get the Bound value from a SPIR-V binary."""
    with open(path, 'rb') as f:
        data = f.read(20)
    if len(data) < 20:
        return None
    words = struct.unpack('<5I', data)
    return words[3]  # Bound is at offset 3 in the header

def get_size(path):
    """Get file size of a SPIR-V binary."""
    return os.path.getsize(path)

def normalize_disasm(disasm):
    """Normalize SPIR-V disassembly for comparison (strip IDs, debug info)."""
    lines = []
    for line in disasm.split('\n'):
        line = line.strip()
        if not line or line.startswith(';'):
            continue
        # Strip debug info (OpName, OpMemberName, OpSource, OpString, OpLine)
        if any(line.startswith(op) for op in ['OpName', 'OpMemberName', 'OpSource', 'OpString', 'OpLine', 'OpModuleProcessed']):
            continue
        lines.append(line)
    return '\n'.join(lines)

def assemble_shadertoy_shader(prefix_path, body_path):
    """Assemble a full shadertoy shader from prefix + body."""
    with open(prefix_path, 'r', encoding='utf-8') as f:
        prefix = f.read()
    with open(body_path, 'r', encoding='utf-8') as f:
        body = f.read()
    return prefix + '\n\n' + body

def resolve_includes(source, base_dir):
    """Simple single-level #include resolution."""
    lines = source.split('\n')
    result = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#include'):
            # Extract filename
            start = stripped.index('"') + 1
            end = stripped.index('"', start)
            filename = stripped[start:end]
            include_path = os.path.join(base_dir, filename)
            try:
                with open(include_path, 'r', encoding='utf-8') as f:
                    include_content = f.read()
                # Strip #version from include only if main source already has it
                if include_content.startswith('#version'):
                    if '#version' in source:
                        nl = include_content.index('\n')
                        include_content = include_content[nl+1:]
                result.append(include_content)
            except FileNotFoundError:
                result.append(line)
        else:
            result.append(line)
    return '\n'.join(result)

def get_wintty_shadertoy_shaders():
    """Get list of wintty shadertoy test shaders."""
    prefix = os.path.join(WINTTY_ROOT, 'src', 'renderer', 'shaders', 'shadertoy_prefix.glsl')
    shaders_dir = os.path.join(WINTTY_ROOT, 'src', 'renderer', 'shaders')
    
    shaders = []
    for name in ['test_shadertoy_crt.glsl', 'test_shadertoy_focus.glsl', 'test_passthrough.glsl']:
        body = os.path.join(shaders_dir, name)
        if os.path.exists(body):
            shaders.append({
                'name': f'shadertoy/{name}',
                'source': assemble_shadertoy_shader(prefix, body),
                'stage': 'fragment',
                'category': 'shadertoy',
            })
    
    return shaders

def get_wintty_builtin_shaders():
    """Get list of wintty's built-in renderer shaders."""
    glsl_dir = os.path.join(WINTTY_ROOT, 'src', 'renderer', 'shaders', 'glsl')
    shaders = []
    
    for name in sorted(os.listdir(glsl_dir)):
        if not name.endswith('.glsl'):
            continue
        if name == 'common.glsl':
            continue
        
        path = os.path.join(glsl_dir, name)
        with open(path, 'r', encoding='utf-8') as f:
            source = f.read()
        
        # Resolve #include
        source = resolve_includes(source, glsl_dir)
        
        # Detect stage
        if '.v.' in name or name.endswith('.vert'):
            stage = 'vertex'
        elif '.f.' in name or name.endswith('.frag'):
            stage = 'fragment'
        else:
            stage = 'fragment'
        
        shaders.append({
            'name': f'builtin/{name}',
            'source': source,
            'stage': stage,
            'category': 'builtin',
        })
    
    return shaders

def test_shader(shader, tmpdir):
    """Test a single shader with both glslpp and glslang."""
    name = shader['name']
    source = shader['source']
    stage = shader['stage']
    
    result = {
        'name': name,
        'stage': stage,
        'category': shader['category'],
        'glslpp_compile': None,
        'glslpp_valid': None,
        'glslpp_bound': None,
        'glslpp_size': None,
        'glslang_compile': None,
        'glslang_valid': None,
        'glslang_bound': None,
        'glslang_size': None,
        'disasm_diff': None,
        'error': None,
    }
    
    # Test glslpp
    glslpp_spv = os.path.join(tmpdir, f'glslpp_{hash(name) % 100000}.spv')
    ok, output = compile_glslpp(source, stage, glslpp_spv)
    result['glslpp_compile'] = ok
    if ok:
        if os.path.exists(glslpp_spv):
            valid, val_output = validate_spv(glslpp_spv)
            result['glslpp_valid'] = valid
            result['glslpp_bound'] = get_bound(glslpp_spv)
            result['glslpp_size'] = get_size(glslpp_spv)
            if not valid:
                result['error'] = f"glslpp spirv-val: {val_output.strip()}"
        else:
            result['glslpp_valid'] = False
            result['error'] = "glslpp: no SPIR-V output file"
    else:
        result['error'] = f"glslpp compile failed: {output[:200]}"
    
    # Test glslang
    glslang_spv = os.path.join(tmpdir, f'glslang_{hash(name) % 100000}.spv')
    ok, output = compile_glslang(source, stage, glslang_spv)
    result['glslang_compile'] = ok
    if ok:
        if os.path.exists(glslang_spv):
            valid, val_output = validate_spv(glslang_spv)
            result['glslang_valid'] = valid
            result['glslang_bound'] = get_bound(glslang_spv)
            result['glslang_size'] = get_size(glslang_spv)
        else:
            result['glslang_valid'] = False
    # else: glslang failure is acceptable (e.g., invalid shader test)
    
    # Compare disassembly if both compiled
    if result['glslpp_compile'] and result['glslang_compile']:
        if os.path.exists(glslpp_spv) and os.path.exists(glslang_spv):
            pp_disasm = normalize_disasm(disassemble_spv(glslpp_spv))
            gl_disasm = normalize_disasm(disassemble_spv(glslang_spv))
            if pp_disasm == gl_disasm:
                result['disasm_diff'] = 'MATCH'
            else:
                # Count lines that differ
                pp_lines = pp_disasm.split('\n')
                gl_lines = gl_disasm.split('\n')
                pp_ops = set(pp_lines)
                gl_ops = set(gl_lines)
                only_pp = pp_ops - gl_ops
                only_gl = gl_ops - pp_ops
                result['disasm_diff'] = f'DIFF (glslpp-only: {len(only_pp)}, glslang-only: {len(only_gl)})'
    
    return result

def print_header(text):
    print(f"\n{BLUE}{'='*70}{RESET}")
    print(f"{BLUE}  {text}{RESET}")
    print(f"{BLUE}{'='*70}{RESET}")

def print_result(r):
    status = ''
    if not r['glslpp_compile']:
        status = f"{RED}COMPILE FAIL{RESET}"
    elif not r['glslpp_valid']:
        status = f"{RED}VAL FAIL{RESET}"
    elif r['disasm_diff'] == 'MATCH':
        status = f"{GREEN}PERFECT MATCH{RESET}"
    elif r['glslang_compile'] and r['glslpp_valid']:
        status = f"{YELLOW}VALID, DIFFERS{RESET}"
    else:
        status = f"{GREEN}VALID{RESET}"
    
    bound_str = ''
    if r['glslpp_bound'] and r['glslang_bound']:
        diff = r['glslpp_bound'] - r['glslang_bound']
        if diff < 0:
            bound_str = f"  bound: {r['glslpp_bound']} vs {r['glslang_bound']} ({GREEN}{diff}{RESET})"
        elif diff > 0:
            bound_str = f"  bound: {r['glslpp_bound']} vs {r['glslang_bound']} ({RED}+{diff}{RESET})"
        else:
            bound_str = f"  bound: {r['glslpp_bound']} == {r['glslang_bound']}"
    elif r['glslpp_bound']:
        bound_str = f"  bound: {r['glslpp_bound']}"
    
    size_str = ''
    if r['glslpp_size'] and r['glslang_size']:
        diff = r['glslpp_size'] - r['glslang_size']
        pct = (diff / r['glslang_size']) * 100 if r['glslang_size'] else 0
        size_str = f"  size: {r['glslpp_size']}B vs {r['glslang_size']}B ({diff:+d}B, {pct:+.1f}%)"
    
    disasm_str = f"  [{r['disasm_diff']}]" if r['disasm_diff'] else ''
    
    print(f"  {status:30s}  {r['name']}{bound_str}{size_str}{disasm_str}")
    if r['error']:
        print(f"    {RED}Error: {r['error'][:200]}{RESET}")

def main():
    # Ensure runner exists
    if not os.path.exists(GLSLPP_RUNNER):
        print(f"{RED}glslpp runner not found at {GLSLPP_RUNNER}{RESET}")
        print("Build it first with:")
        print("  ZIG=... zig build-exe -OReleaseSafe --dep glslpp ...")
        sys.exit(1)
    
    # Collect all shaders
    shadertoy_shaders = get_wintty_shadertoy_shaders()
    builtin_shaders = get_wintty_builtin_shaders()
    all_shaders = shadertoy_shaders + builtin_shaders
    
    print(f"{BLUE}wintty Shader Audit: glslpp vs glslang{RESET}")
    print(f"  Shadertoy shaders: {len(shadertoy_shaders)}")
    print(f"  Built-in shaders:  {len(builtin_shaders)}")
    print(f"  Total:             {len(all_shaders)}")
    
    with tempfile.TemporaryDirectory(prefix='glslpp_audit_') as tmpdir:
        # Test shadertoy shaders
        print_header("SHADERTOY SHADERS (prefix + body -> fragment)")
        shadertoy_results = []
        for shader in shadertoy_shaders:
            r = test_shader(shader, tmpdir)
            shadertoy_results.append(r)
            print_result(r)
        
        # Test built-in shaders
        print_header("BUILT-IN RENDERER SHADERS")
        builtin_results = []
        for shader in builtin_shaders:
            r = test_shader(shader, tmpdir)
            builtin_results.append(r)
            print_result(r)
    
    # Summary
    all_results = shadertoy_results + builtin_results
    print_header("SUMMARY")
    
    glslpp_compile_ok = sum(1 for r in all_results if r['glslpp_compile'])
    glslpp_valid_ok = sum(1 for r in all_results if r['glslpp_valid'])
    glslang_compile_ok = sum(1 for r in all_results if r['glslang_compile'])
    perfect_match = sum(1 for r in all_results if r['disasm_diff'] == 'MATCH')
    glslpp_smaller = sum(1 for r in all_results if r['glslpp_bound'] and r['glslang_bound'] and r['glslpp_bound'] < r['glslang_bound'])
    glslpp_larger = sum(1 for r in all_results if r['glslpp_bound'] and r['glslang_bound'] and r['glslpp_bound'] > r['glslang_bound'])
    same_bound = sum(1 for r in all_results if r['glslpp_bound'] and r['glslang_bound'] and r['glslpp_bound'] == r['glslang_bound'])
    
    total_bound_glslpp = sum(r['glslpp_bound'] for r in all_results if r['glslpp_bound'])
    total_bound_glslang = sum(r['glslang_bound'] for r in all_results if r['glslang_bound'])
    total_size_glslpp = sum(r['glslpp_size'] for r in all_results if r['glslpp_size'])
    total_size_glslang = sum(r['glslang_size'] for r in all_results if r['glslang_size'])
    
    print(f"  glslpp compiled:     {glslpp_compile_ok}/{len(all_results)}")
    print(f"  glslpp spirv-val:    {glslpp_valid_ok}/{len(all_results)}")
    print(f"  glslang compiled:    {glslang_compile_ok}/{len(all_results)}")
    print(f"  Perfect disasm match: {perfect_match}/{len(all_results)}")
    print(f"  Bound comparison:")
    print(f"    glslpp smaller:    {glslpp_smaller}")
    print(f"    glslpp same:       {same_bound}")
    print(f"    glslpp larger:     {glslpp_larger}")
    if total_bound_glslang > 0:
        print(f"    Total bound:       {total_bound_glslpp} vs {total_bound_glslang} ({total_bound_glslpp - total_bound_glslang:+d}, {(total_bound_glslpp - total_bound_glslang)/total_bound_glslang*100:+.1f}%)")
    if total_size_glslang > 0:
        print(f"    Total size:        {total_size_glslpp}B vs {total_size_glslang}B ({total_size_glslpp - total_size_glslang:+d}B, {(total_size_glslpp - total_size_glslang)/total_size_glslang*100:+.1f}%)")
    
    # Failures
    failures = [r for r in all_results if not r['glslpp_compile'] or (r['glslpp_compile'] and not r['glslpp_valid'])]
    if failures:
        print(f"\n{RED}FAILURES ({len(failures)}):{RESET}")
        for r in failures:
            print(f"  {RED}X{RESET} {r['name']}")
            if r['error']:
                print(f"    {r['error'][:200]}")
    
    # Verdict
    print_header("VERDICT")
    if glslpp_valid_ok == len(all_results):
        print(f"  {GREEN}OK{RESET} ALL {len(all_results)} SHADERS PASS spirv-val{RESET}")
        if total_bound_glslpp < total_bound_glslang:
            print(f"  {GREEN}OK{RESET} glslpp output is {(total_bound_glslang-total_bound_glslpp)/total_bound_glslang*100:.1f}% smaller than glslang{RESET}")
        print(f"  {GREEN}READY FOR INTEGRATION STEP 2{RESET}")
    elif glslpp_valid_ok > 0:
        print(f"  {YELLOW}!!{RESET} {glslpp_valid_ok}/{len(all_results)} shaders pass -- partial compatibility{RESET}")
        print(f"  {YELLOW}  Fix failing shaders before integration{RESET}")
    else:
        print(f"  {RED}XX{RESET} NO SHADERS PASS -- significant work needed{RESET}")
    
    return 0 if glslpp_valid_ok == len(all_results) else 1

if __name__ == '__main__':
    sys.exit(main())
