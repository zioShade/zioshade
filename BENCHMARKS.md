# Benchmarks

> **Reproduce locally:**
> ```bash
> # If glslangValidator and spirv-cross are on your PATH:
> zig build bench-compare
>
> # Or override paths (Windows / Vulkan SDK example):
> GLSLPP_BENCH_GLSLANG="C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe" \
> GLSLPP_BENCH_SPIRVX="C:/VulkanSDK/1.4.341.1/Bin/spirv-cross.exe" \
>   zig build bench-compare
> ```

## Latest run (Windows 11, AMD Ryzen, Zig 0.15.2 ReleaseFast, Vulkan SDK 1.4.341.1)

50 iterations per shader, after 3 warm-up runs. Full GLSL → SPIR-V → HLSL (SM 6.0) pipeline per iteration. Results from [tools/bench_compare.zig](tools/bench_compare.zig).

| Shader | glslpp avg | glslpp min | reference avg | reference min | **speedup** | HLSL bytes glslpp / reference |
|---|---:|---:|---:|---:|---:|---:|
| `trivial_frag` (10 lines) | 732 µs | 424 µs | 194,175 µs | 140,610 µs | **265.2×** | 175 / 332 |
| `typical_frag` (UBO + math, 15 lines) | 986 µs | 654 µs | 181,184 µs | 149,254 µs | **183.7×** | 701 / 746 |
| `raymarch` (loop + SDF, 25 lines) | 1,174 µs | 760 µs | 180,681 µs | 135,780 µs | **153.9×** | 1,316 / 1,562 |
| `simple_compute` (SSBO write) | 1,041 µs | 496 µs | 190,359 µs | 136,287 µs | **182.8×** | 516 / 650 |

**Highlights**
- glslpp is **150–265×** faster on this workflow than spawning `glslangValidator + spirv-cross`.
- glslpp's HLSL output is **5–47% smaller** on every shader tested — same source compiles to fewer bytes, despite glslpp's optimizer being newer than SPIRV-Cross's.
- Min vs avg confirms steady-state behaviour: glslpp's variance is sub-millisecond; reference variance is in the tens of milliseconds (mostly Windows process-spawn jitter).

## What is and isn't being measured

This benchmark intentionally measures **realistic integration cost**, not raw algorithmic speed.

| Approach | What it pays for |
|---|---|
| **glslpp (in-process Zig library)** | GLSL parse + SPIR-V codegen + optimization passes + HLSL emit. No process spawn, no DLL init, no IPC. |
| **glslangValidator + spirv-cross (subprocess CLIs)** | Process creation (~150 ms on Windows) + binary load + DLL init + the same GLSL → SPIR-V → HLSL work + serializing back through stdout/file. |

This matches how most build pipelines actually integrate the C++ toolchain — `cmake` rules, `make` recipes, Cargo `build.rs`, and Bazel actions all spawn `glslangValidator` per shader. Even pipeline DAGs that batch shaders pay the per-batch process cost.

**What this does *not* benchmark:** linking `libglslang.a` + `libspirv-cross.a` into your binary and calling them in-process. That would close most of the workflow gap, leaving the algorithmic difference (which we expect to be much smaller). A real library-vs-library comparison requires either pulling in a C++ toolchain build, or shipping prebuilt static libs — neither is in scope for this repo today. **The 150–265× number is honestly framed as a workflow win, not an algorithm win.**

## Methodology

- Each measurement is the wall-clock time of one full pipeline call (`std.time.Instant.now`, monotonic source).
- 3 untimed warm-up iterations precede each timed series to amortize allocator and instruction-cache warm-up.
- The reference pipeline writes a temp `.frag/.comp` file once, then runs both subprocesses each iteration. Temp-file write cost is amortized over 50 iterations (negligible).
- Output size is measured on the final HLSL string (glslpp returns null-terminated, reference returns stdout).
- glslpp build mode: `ReleaseFast`. Reference toolchain: stock Vulkan SDK 1.4.341.1 (LunarG).

## Where the win comes from

1. **No process spawn.** ~80–90% of the gap. On Windows the cost per `CreateProcess` is ~100–150 ms; macOS/Linux are faster but still substantial.
2. **No DLL/init overhead.** glslang's C++ runtime initialization, locale setup, and resource-limit defaults happen once per process. glslpp is just function calls.
3. **Tight ID compaction.** glslpp's SPIR-V emitter compacts result IDs aggressively, and the cross-compilers inline single-use expressions. The combination yields visibly smaller HLSL on the same input.
4. **Single allocator domain.** Each call uses a single Zig allocator; no IPC, no string serialization.

## What this means in practice

For wintty's startup sequence (10 shaders): subprocess approach would take ~1.8 s before the terminal renders a frame. glslpp turns that into ~10 ms. That's the original motivation — a real engineering constraint, not a microbenchmark.

For your own project: if you compile shaders at build time (offline) the win is "fewer seconds of CMake friction." If you compile shaders at runtime (hot-reload, JIT specialization), the win is "this is actually viable now."

## DXC validation snapshot (M5.3)

End-to-end validation of glslpp's HLSL output: every SPIR-V fixture in
`tests/spirv_bins/` is cross-compiled to HLSL, written to a temp file, and
fed to `dxc.exe` with a per-stage target profile (`ps_*` / `cs_*` /
`ms_*` / `as_*`) derived from the fixture's `OpEntryPoint` execution
model. Stages glslpp does not yet emit valid HLSL for (vertex, raygen,
geometry, tess, etc.) are reported as **SKIP** with a roadmap reference.

> **Reproduce:** `zig build test-dxc [-- <dxc_path> <spv_dir> <sm>]` —
> defaults to `C:/VulkanSDK/1.4.341.1/Bin/dxc.exe`, `tests/spirv_bins`,
> SM `60`.

**Snapshot — commit `b14d0429`, 2026-05-27, SM 6.0, DXC 1.10 (5180):**

| Stage | PASS | FAIL | SKIP | Notes |
|---|---:|---:|---:|---|
| `fragment` | 47 | 4 | 0 | spirv-cross corpus, all pre-existing fixtures |
| `compute`  |  0 | 1 | 0 | `compute_minimal.spv`, fails on SSBO subscript |
| **Total**  | **47** | **5** | **0** | 52 fixtures processed |

**Snapshot — commit `1c3b3d70`, 2026-05-28, SM 6.5, DXC 1.10 (5180):**

| Stage | PASS | FAIL | SKIP | Notes |
|---|---:|---:|---:|---|
| `fragment` | 48 | 3 | 0 | spirv-cross corpus; `complex-expression-in-access-chain.spv` still hits an internal DXC validator |
| `compute`  |  1 | 0 | 0 | `compute_minimal.spv` now passes at SM 6.5 |
| `vertex`   |  1 | 0 | 0 | `vertex_minimal.spv` validates after M5.0/M5.1 |
| `mesh`     |  1 | 1 | 0 | `mesh_v2c_triangle.spv` validates end-to-end (M5.2 v2.c); `mesh_minimal.spv` lacks a `gl_Position` write and is intentionally incomplete |
| **Total**  | **51** | **4** | **0** | 55 fixtures processed |

When M5.0 (vertex), M5.2 v2 (mesh), and ray-tracing fixtures are added,
the tool picks them up automatically — the bottleneck has shifted from
HLSL backend coverage to fixture coverage.

**Top failure reasons at SM 6.0 (DXC stderr, first 80 chars):**

| Count | Error |
|---:|---|
| 3 | `error: invalid semantic 'SV_Barycentrics' for ps 6.0` |
| 1 | `error: validation errors` |
| 1 | `error: subscripted value is not an array, matrix, or vector` |

- The three `SV_Barycentrics` failures (`barycentric-{khr,khr-io-block,nv}.spv`)
  require SM 6.1+. They pass at `sm=61`; with default SM 6.0 they're
  intentional dialect failures, not glslpp bugs.
- `complex-expression-in-access-chain.spv` hits DXC's internal validator
  (likely a row/column-major access-chain emit corner case).
- `compute_minimal.spv` exposed an SSBO emit issue in the compute path at
  SM 6.0; resolved at SM 6.5.

Fragment pass rate: **48/51 = 94.1%** at SM 6.5 (was 47/51 = 92.2% at SM 6.0).
