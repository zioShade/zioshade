# Performance

**[BENCHMARKS.md](../BENCHMARKS.md) is the source of truth for zioshade's performance
claims.** It carries the measured numbers, the methodology, and the honest framing of what
each figure does and does not prove. This file used to duplicate that material with
older, unstamped estimates; those have been removed rather than carried forward.

The two headline results, both measured (see BENCHMARKS.md for the full tables):

- **Library vs library, in-process:** roughly **1.4-1.6x** faster than SPIRV-Cross on the
  median cell (SPIR-V to GLSL / HLSL / MSL, same SPIR-V input, no subprocess on either
  side). This is the honest raw-throughput figure.
- **Workflow, vs subprocess CLIs:** **150-265x** faster than spawning
  `glslangValidator + spirv-cross` per shader. That gap is dominated by process-spawn
  cost, so it is a **workflow win, not an algorithm win**, and BENCHMARKS.md says so
  explicitly.

An earlier revision of this file advertised a "25-500x" speedup and an *estimated*
library-API comparison row. Both were projections, not measurements, and the measured
library-vs-library result above contradicts them. They are retracted.

## Local snapshot (`zig build bench`)

Apple M2, macOS 26.5.1, Zig 0.15.2, `ReleaseFast`, commit `5cc77f1`, 2026-08-04.
Cross-compile only (pre-compiled SPIR-V to backend source), 2000 iterations each:

| Direction | Avg |
|---|---:|
| SPIR-V to HLSL | 112 µs |
| SPIR-V to GLSL | 89 µs |
| SPIR-V to MSL | 97 µs |

One machine, one run, absolute numbers only. It is here to show the order of magnitude of
an in-process cross-compile, not as a comparative claim; the comparisons live in
BENCHMARKS.md.

## Architectural reasons the in-process path is cheap

These are properties of the design, not measurements:

1. **No C++ runtime.** Pure Zig, no system dependencies.
2. **No process spawning.** In-process compilation.
3. **No DLL loading.** Statically linked.
4. **Single allocation context.** Arena allocator, bulk free.
5. **All backends from one SPIR-V pass.** HLSL + GLSL + MSL + WGSL off the same module.

## Reproducing

```bash
zig build bench            # quick per-shader zioshade-only timings (tools/bench_quick.zig)
zig build bench-compare    # zioshade vs subprocess glslang + spirv-cross (tools/bench_compare.zig)
zig build lib-bench        # zioshade vs in-process SPIRV-Cross C API; needs the Vulkan SDK libs
```

`bench-compare` picks up `glslangValidator` and `spirv-cross` from `PATH`, or from
`ZIOSHADE_BENCH_GLSLANG` / `ZIOSHADE_BENCH_SPIRVX`. `lib-bench` needs the SPIRV-Cross
static libs (`-Dvulkan-sdk=<path>`, or `$VULKAN_SDK`). See BENCHMARKS.md for the
invocation details.
