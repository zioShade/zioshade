# Test Coverage

What `zig build conformance` actually validates: every shader listed below is compiled GLSL → SPIR-V by glslpp and the resulting SPIR-V binary is checked with `spirv-val`. Latest run: **2,087 / 2,087 PASS** on Windows 11 / Zig 0.15.2 / Vulkan SDK 1.4.341.1.

## Test corpora

| Suite | Path | Files | Origin | What it stresses |
|---|---|---:|---|---|
| **`spirv-cross` reference** | [`tests/spirv-cross/`](../tests/spirv-cross/) | 1,669 | Imported from [KhronosGroup/SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) `shaders/*` | Real-world GLSL patterns: post-processing, deferred lighting, GPU sort, normal mapping, the long tail. |
| **`glslang-430` reference** | [`tests/glslang-430/`](../tests/glslang-430/) | 42 | Subset of [KhronosGroup/glslang](https://github.com/KhronosGroup/glslang) `Test/spv.*` | Spec-corner cases: `WorkgroupMemoryExplicitLayout`, atomic `fp16` vec, sample qualifiers. |
| **`ghostty`** | [`tests/ghostty/`](../tests/ghostty/) | 10 | Production shaders from [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) | Real fragment/vertex pairs for terminal cell rendering, backgrounds, images. |
| **`compute`** | [`tests/compute/`](../tests/compute/) | 13 | Hand-authored | `local_size_*`, SSBO read/write, shared memory, `subgroupBallot`, `subgroupAdd`. |
| **`geometry`** | [`tests/geometry/`](../tests/geometry/) | 16 | Hand-authored | Geometry stage I/O, `EmitVertex`/`EndPrimitive`, layered rendering, viewport selection. |
| **`tessellation`** | [`tests/tessellation/`](../tests/tessellation/) | 13 | Hand-authored | TCS + TES pairs, patch quads/triangles, `gl_TessLevel*`, control-point I/O. |
| **`mesh_task`** | [`tests/mesh_task/`](../tests/mesh_task/) | 4 | Hand-authored | `EXT_mesh_shader` task + mesh stages. |
| **`ray_tracing`** | [`tests/ray_tracing/`](../tests/ray_tracing/) | 3 | Hand-authored | Raygen / closest-hit / miss; `KHR_ray_tracing_pipeline` types. |
| **`conformance/stress`** | [`tests/conformance/stress/`](../tests/conformance/stress/) | 457 | Authored to lock in fixed-bug behaviour | Topic-by-topic regression cases — see breakdown below. |

The conformance runner ([`tests/runner.zig`](../tests/runner.zig)) walks each suite, skips include-only fixtures and known-bad-input markers (`.error.`, `.asm.`, `link.`, `.nocompat.`), and reports PASS / FAIL / SKIP per suite plus a grand total.

## What the 457 stress cases cover

Auto-categorized from filename keywords ([scripts/categorize_stress.py](../scripts/categorize_stress.py)):

| # | Category | Examples |
|---:|---|---|
| 74 | Control flow (if/else, switch, ternary) | `deep_if6.frag`, `nested_switch.frag`, `const_branch.frag`, `cond_break.frag` |
| 73 | Misc / new feature regressions | `multi_render_target.frag`, `front_facing.frag`, `wgsl_clip_distance.vert`, `fragcoord_all.frag` |
| 53 | Loops (`for`, `while`, `do-while`) | `wgsl_while_phi.frag`, `dowhile_struct.frag`, `for_loop.frag`, `discard_in_loop.frag` |
| 52 | Structs and arrays | `nested_arr_struct.frag`, `struct_copy.frag`, `array_of_structs.frag`, `arr_param.frag` |
| 44 | Vectors and matrices | `mat4_transform.frag`, `swizzle_assign.frag`, `mat3_basic.frag`, `vec3_dot.frag` |
| 27 | Function calls / chains | `deep_call_chain.frag`, `fn_chain.frag`, `inout_param.frag`, `4param_fn.frag` |
| 26 | Early return / discard | `multi_early_ret.frag`, `discard_struct.frag`, `nested_discard.frag` |
| 26 | Integer / bitwise math | `int_logic.frag`, `bitfield_ops.frag`, `uint_ops.frag`, `bool_int_arith.frag` |
| 22 | Compute / atomic / SSBO | `compute_nested.comp`, `wgsl_atomic.comp`, `wgsl_bitonic.comp`, `compute_shared.comp` |
| 20 | Specific algorithms / shader patterns | `mandelbrot.frag`, `voronoi.frag`, `phong.frag`, `pbr.frag`, `ray_sphere.frag` |
| 16 | Floating-point math / built-ins | `builtin_math.frag`, `smooth_noise.frag`, `saturate.frag`, `deriv_cond.frag` |
| 13 | Textures / sampling | `wgsl_cubemap.frag`, `wgsl_tex_lod.frag`, `texel_sample.frag` |
|  8 | Geometry / vertex specifics | `vertex_pts.vert`, `tcs_quads2.tesc`, `tese_bilinear.tese`, `depth_write.frag` |
|  3 | Memory / load–store / aliasing | `branch_store_fwd.frag`, `addr_alias.frag`, `load_after_store.frag` |

Each stress case is a single-purpose shader that, when broken in glslpp, would have caused a specific regression (incorrect output, `spirv-val` failure, or backend emit error). New cases are added every time a bug is fixed in glslpp's emitter — see commit history.

## Backend-specific coverage

| Backend | Where it's exercised | Approx count |
|---|---|---:|
| **SPIR-V output (the conformance oracle)** | All 2,087 fixtures above | 2,087 |
| **HLSL backend (SM 6.0)** | `zig build test-hlsl` (780 tests) + DXC compilation of 47/51 prebuilt SPIR-V fixtures via `tools/dxc_batch_test.zig` | 780 + 47 |
| **MSL backend** | `zig build test` (52 msl-tests) + cross-compile of every stress fixture | 52 + 457 |
| **GLSL round-trip** | `zig build test` (122 glsl-tests) + reference suite | 122 |
| **WGSL backend** | `zig build test` (8 wgsl-tests) + WGSL-prefixed stress fixtures (321 cases under `tests/conformance/stress/wgsl_*`) | 8 + 321 |
| **`naga` validation of WGSL output** | `zig build test-realworld` — separate step; not part of `zig build conformance`. See `tests/realworld_tests.zig` and the [real-world corpus snapshot](./realworld-corpus.md). | 13 hand-authored shaders, exercises all 4 backends + naga |

## Reproducibility

```bash
zig build conformance               # all 2,087 spirv-val fixtures
zig build test --summary all        # 1,600 unit tests across all modules
zig build test-hlsl --summary all   # 780 HLSL backend tests
zig build fuzz -- --count 50000     # 50k random GLSL inputs, structured fuzzer
zig build bench-compare             # head-to-head vs glslang+spirv-cross
```

CI runs the first four on Linux + macOS + Windows on every PR ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).
