# Autoresearch Handoff Notes — Session 12

## Current State
- **199/199 spirv-val pass**, 9/199 real output mismatches, 9/10 Ghostty shaders
- Branch: `autoresearch/conformance-20260423`
- Current HEAD: `128d091` (float vector constant_composite)
- **49/199 instruction-level exact matches** with glslang (up from 42)
- ID bound ratio: 0.8512 (slightly higher due to constant IDs)
- ~3ms compile time for complex shaders

## What was done this session
1. Confirmed baseline: 9 mismatches, 199/199 spirv-val
2. Implemented float vector OpConstantComposite for all-literal type constructors
   - Multi-arg: `vec4(1.0, 0.0, 0.0, 1.0)` → OpConstantComposite
   - Scalar-splat: `vec4(10.0)` → OpConstantComposite
   - 7 additional instruction-level exact matches (42→49)
3. Verified all Ghostty shaders still pass

## Remaining 9 mismatches (all vendor extensions)
1. `block-match-sad.spv14.frag` — QCOM image processing (out=0/2)
2. `block-match-ssd.spv14.frag` — QCOM image processing (out=0/2)
3. `box-filter.spv14.frag` — QCOM image processing (out=0/2)
4. `sample-weighted.spv14.frag` — QCOM image processing (out=0/2)
5. `nonuniform-qualifier.vk.nocompat.frag` — runtime arrays + nonuniformEXT
6. `rq-position-fetch.vk.spv14.nocompat.frag` — ray tracing
7. `tensor.nocompat.noopt.vk.frag` — ARM tensor (out=0/1)
8. `tensor_params.nocompat.invalid.vk.comp` — ARM tensor (buf=0/1)
9. `tensor_read.nocompat.noopt.vk.comp` — ARM tensor (buf=0/1)

## Key files modified this session
- `src/semantic.zig` — float constant_composite detection in type_constructor (multi-arg + scalar-splat paths)

## Build command
```bash
ZIG=/c/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe
$ZIG build-exe -OReleaseSafe --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe
```

## Next session ideas
- Skip identity VectorShuffle (vec3.xyz = vec3) — 3+ shaders affected
- Extend constant_composite to handle `vec4(expr)` when expr resolves to known constant
- Runtime arrays for nonuniform-qualifier shader
- GPU visual correctness verification (Phase 3)
