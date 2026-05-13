#!/usr/bin/env python3
"""Split compact_ids.zig into core + passes for faster compilation."""
import re, os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

with open('src/compact_ids.zig', 'r') as f:
    lines = f.readlines()

# Find compactIds function end
compactIds_end = None
in_func = False
depth = 0
for i, line in enumerate(lines):
    if 'pub fn compactIds(' in line:
        in_func = True
        depth = 0
    if in_func:
        for c in line:
            if c == '{': depth += 1
            elif c == '}': depth -= 1
        if depth == 0 and i > 225:
            compactIds_end = i
            break
assert compactIds_end, "compactIds end not found"

# Write core file (everything up to and including compactIds)
with open('src/compact_ids.zig', 'w') as f:
    f.writelines(lines[:compactIds_end+1])
    f.write('\n')

# Build passes file
header = [
    '// SPDX-License-Identifier: MIT OR Apache-2.0\n',
    '// SPIR-V optimization passes. Split from compact_ids.zig.\n',
    '// Only needed by codegen.zig for the full optimization pipeline.\n',
    'const std = @import("std");\n',
    'const compact_ids = @import("compact_ids.zig");\n',
    '\n',
]
pass_lines = lines[compactIds_end+1:]
fixed = []
for line in pass_lines:
    if 'getOpInfo(' in line and 'pub fn getOpInfo' not in line and 'fn getOpInfo' not in line:
        line = re.sub(r'\bgetOpInfo\(', 'compact_ids.getOpInfo(', line)
    if 'compactIds(' in line and 'pub fn compactIds' not in line and 'fn compactIds' not in line:
        line = re.sub(r'\bcompactIds\(', 'compact_ids.compactIds(', line)
    fixed.append(line)

with open('src/compact_ids_passes.zig', 'w') as f:
    f.writelines(header)
    f.writelines(fixed)

print(f'compact_ids.zig: {compactIds_end+1} lines (core)')
print(f'compact_ids_passes.zig: {len(header)+len(fixed)} lines (passes)')

# Update codegen.zig, kernel_fusion.zig, loop_counter_phi.zig
passes_list = [
    'deadCodeElim', 'mergeAccessChains', 'deadLoopElim', 'retargetEmptyBlocks',
    'mergeBlocks', 'mergeNonEmptyBlocks', 'foldSelect', 'dedupStructTypes',
    'dedupArrayTypes', 'dedupPointerTypes', 'elimSelfRefArithmetic',
    'eliminateDoubleNegate', 'foldNegateIntoAddSub', 'redundantStoreElim',
    'algebraicSimpl', 'elimUnreachableCalls', 'inlineTrivialFuncs',
    'moveVarToEntry', 'elimUninitVars', 'fixEarlyAccessVars',
    'elimRedundantLoads', 'foldCompositeExtract', 'cseWithinBlocks',
    'constStoreForward', 'constFold', 'scatterStoreToComposite',
    'storeForwardExtract', 'elimTrivialEntryPoint', 'elimIdentityShuffle',
    'foldShuffleFromComposite', 'elimDeadVoidCalls', 'elimDeadVarStores',
    'copyMemoryOpt', 'elimIdentityStores', 'elimDeadFunctions',
    'hoistInvariantACs', 'branchMergePhi', 'elimUnusedImports',
    'elimUnusedGlobals', 'stripDeadDebugInfo', 'dedupFunctionTypes',
    'fixTypeOrdering', 'foldConstBranches', 'elimUnreachableBlocks',
    'foldConstCompositeExtract', 'simplifyTrivialPhi',
]

for fname in ['src/codegen.zig', 'src/kernel_fusion.zig', 'src/loop_counter_phi.zig']:
    with open(fname, 'r') as f:
        text = f.read()
    # Add opt import if not already present
    if 'const opt = @import("compact_ids_passes.zig")' not in text:
        text = text.replace(
            'const compact_ids = @import("compact_ids.zig");',
            'const compact_ids = @import("compact_ids.zig");\nconst opt = @import("compact_ids_passes.zig");',
        )
    # Replace pass function calls
    for p in passes_list:
        text = text.replace(f'compact_ids.{p}', f'opt.{p}')
    with open(fname, 'w') as f:
        f.write(text)
    opt_count = text.count('opt.')
    print(f'{fname}: {opt_count} opt. references')
