# Autoresearch Handoff Notes — Session 11

## Current State
- **199/199 spirv-val pass**, 9/199 real output mismatches, 9/10 Ghostty shaders, 0 total failures
- Branch: `autoresearch/conformance-20260423`
- Current HEAD: `c985506` (swizzle compound mul optimization)
- 39/199 instruction-level exact matches with glslang
- ID bound ratio: 0.8355 (we use ~84% of glslang's IDs)
- ~3ms compile time for complex shaders

## What was done this session
1. Fixed OpControlBarrier opcode: was 227 (OpAtomicLoad!), now 224 (correct)
2. Implemented proper barrier()/memoryBarrier*() SPIR-V instruction generation
3. Barrier constants created via semantic analyzer's `getConstInt()` (avoids codegen type_section splice issues)
4. Optimized float-to-vector splat: skip for `*=` and use `VectorTimesScalar` directly
5. Optimized swizzle compound multiply to use `VectorTimesScalar` instead of splat+`FMul`
6. Instruction-level matches improved: 39 → 42 / 199
7. ID bound ratio improved: 0.8355 → 0.8352

## Remaining 9 mismatches (all vendor extensions — not quick wins)
1. `block-match-sad.spv14.frag` — QCOM image processing (out=0/2)
2. `block-match-ssd.spv14.frag` — QCOM image processing (out=0/2)
3. `box-filter.spv14.frag` — QCOM image processing (out=0/2)
4. `sample-weighted.spv14.frag` — QCOM image processing (out=0/2)
5. `nonuniform-qualifier.vk.nocompat.frag` — needs runtime arrays + nonuniformEXT
6. `rq-position-fetch.vk.spv14.nocompat.frag` — needs ray tracing
7. `tensor.nocompat.noopt.vk.frag` — ARM tensor operations
8. `tensor_params.nocompat.invalid.vk.comp` — ARM tensor (buf=0/1)
9. `tensor_read.nocompat.noopt.vk.comp` — ARM tensor (buf=0/1)

## Key technical details
- OpControlBarrier = 224 (NOT 227 which is OpAtomicLoad)
- OpMemoryBarrier = 225 (correct)
- barrier() → OpControlBarrier(Workgroup, Workgroup, AcquireRelease|WorkgroupMemory=264)
- memoryBarrier() → OpMemoryBarrier(Device=1, AcquireRelease|UniformMemory=72)
- memoryBarrierShared() → OpMemoryBarrier(Workgroup=2, AcquireRelease|WorkgroupMemory=264)
- memoryBarrierImage/Buffer → OpMemoryBarrier(Device=1, AcquireRelease|UniformMemory=72)
- groupMemoryBarrier → OpMemoryBarrier(Workgroup=2, AcquireRelease|UniformMemory=72)

## Build command
```
ZIG=/c/Users/Alessandro/zig-0.15.2-extracted/zig-x86_64-windows-0.15.2/zig.exe
$ZIG build-exe -OReleaseSafe --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe
```

## Benchmark command
```
python3 autoresearch_bench.py
```

## Key files modified
- `src/spirv.zig` — OpControlBarrier=224, OpMemoryBarrier=225
- `src/ir.zig` — control_barrier, memory_barrier IR tags
- `src/semantic.zig` — barrier builtin handling with getConstInt
- `src/codegen.zig` — barrier instruction emission

## Ideas for future work
- See `autoresearch.ideas.md` for prioritized list
- GPU visual correctness verification (Phase 3)
- Normalized instruction comparison for 190 matching shaders
- textureOffset (non-shadow) — ConstOffset for image_sample implicit lod
- Runtime arrays (OpTypeRuntimeArray) — would help nonuniform-qualifier
- 16-bit type constructors when NV atomic fp16 is properly supported
