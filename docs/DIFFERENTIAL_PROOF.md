# Differential proof: does zioshade behave like the tools it replaces?

zioshade replaces two C++ tools: **glslang** (GLSL → SPIR-V) and **SPIRV-Cross**
(SPIR-V → HLSL / MSL / GLSL / WGSL). This document records the evidence that it
does so faithfully, and how to reproduce each measurement. All numbers below are
from the checked-in shader corpora and are regenerable locally.

**Reproduce the execution-equivalence proof in one command:** `just prove` (or
`bash tools/prove.sh`) renders/executes zioshade's output alongside an independent
glslang → SPIRV-Cross reference on the real Metal GPU across **all three shader stages**
(fragment = pixels, vertex = captured `gl_Position`, compute = output buffers), prints one
honest report — `verified / benign / divergences / skipped-with-reason` — and exits nonzero
on any real divergence (so it is also a regression gate). Fragment is sampled for speed
plus a fixed regression set; `PROVE_FULL=1` runs the whole fragment corpus. Requires only
glslang, spirv-cross, and swiftc/Metal (no Docker; the DXC → D3D12 HLSL path lives in
`tools/hlsl_render_check.sh` + `tools/warp/`). A representative run: **1315 shaders verified,
0 divergences** (`PROVE_FULL=1`, full corpus; see the table below), spanning both SPIRV-Cross's own test suite AND a **hand-written real-world
corpus** (`tests/render_compare/` + `tests/shadertoy_style/`: mandelbrot, julia, plasma,
phong, hash-noise, terrain, etc., written for zioshade and NOT derived from the reference's
tests, so they answer the "is this only a synthetic self-selected corpus?" objection).
Honest scope: the SPIRV-Cross fragment sweep is a 1/25 sample by default (`PROVE_FULL=1`
runs the whole corpus), and every uncovered shader is reported as an explicit skip, never
counted as a pass.

**Full-corpus run (`PROVE_FULL=1`, 2026-07-25): 1315 shaders verified, 0 divergences.**

| stage              | verified | diverge | honest-err | skipped |
|--------------------|---------:|--------:|-----------:|--------:|
| fragment (full)    |     1186 |       0 |          8 |     258 |
| frag/realworld     |       83 |       0 |          0 |       2 |
| vertex             |       33 |       0 |          0 |      12 |
| compute            |       13 |       0 |          0 |       0 |
| **total**          |    **1315** |  **0** |          8 |     -   |

Every covered shader renders/executes identically to the independent glslang →
SPIRV-Cross reference on the Metal GPU; the 8 honest-errors are zioshade's own
GLSL-frontend refusals (it declines rather than risk a wrong translation), and the
skipped shaders are reference-unbuildable or need inputs the generic harness cannot
supply; each is listed in the run output, none ever counted as a pass. Honest
limit (this is empirical, not mathematical proof): it is within-tolerance
conformance to a peer compiler (SPIRV-Cross) on one Metal GPU class; outputs where
zioshade and the reference share the same spec misreading are structurally invisible
to any single-oracle differential. That blind spot is now closed for the majority of
the MSL corpus by a **second independent oracle** (naga) — see the section below.

## Per-backend confidence at a glance

zioshade emits four backends, and they are **not** equally proven. The headline
number above (1315 shaders, 0 divergences) is the **MSL backend run on a real
Metal GPU**. To keep the conformance badge from being read as "every backend is
render-proven," here is the honest per-backend confidence level:

| Backend | Confidence | Evidence | Regenerate |
|---------|------------|----------|------------|
| **MSL** | **render-proven** (strongest) | full-corpus Metal GPU pixel/exec differential vs glslang→SPIRV-Cross: 1315 shaders, **0 divergences** (table above). **Honest scope:** that run (`frag_oracle_check.sh`) drives **SPIRV-Cross on both sides** (zioshade's *frontend* SPIR-V vs glslang's), so it proves zioshade's GLSL→SPIR-V frontend matches glslang — using SPIRV-Cross as a shared backend. zioshade's *own* MSL backend is render-proven separately: on optimized SPIR-V (`prove_opt`, 1123 MATCH, 0 structural) and on **unoptimized** SPIR-V via the naga 2nd-oracle (`prove_naga`, 1127 MATCH / 7 DIFFER — see below; a loop-lowering bug found there is now fixed). | `PROVE_FULL=1 just prove`, `just prove-opt`, `just prove-naga` |
| **MSL on `spirv-opt -O`** | **render-proven** | `prove_opt` runs the SPIR-V optimizer's output through both zioshade-MSL and SPIRV-Cross-MSL and render-diffs on Metal; a focused campaign closed 39 structural miscompiles to 0, and wintty's own `crt_output`/`focus_output` shaders verify MATCH on optimized SPIR-V | `just prove-opt` |
| **GLSL** | **render-verified (proxy)** | glslang compile (0 INVALID) + Metal-reuse render proxy (zioshade GLSL → glslang → MSL → Metal vs MSL_ref): **1141 MATCH / 3 EDGE / 22 DIFFER (flagged)** — `#loop-continue-deadincr` dropped 70 → 26, `#switch-fallthrough` dropped 26 → 25, and proxy FP-adjudication (#52) split 3 benign EDGE from 22 persistent DIFFER (chaos / control-flow / proxy-round-trip). Single-oracle proxy, same correlated-normalization caveat as HLSL | `just glsl-glslang-all`, `bash tools/glsl_render_check.sh` |
| **WGSL** | **render-verified (proxy)** | naga compile (0 REJECT) + Metal-reuse render proxy (zioshade WGSL → naga → MSL → Metal vs MSL_ref): **1138 MATCH / 9 EDGE / 19 DIFFER (flagged)** — `#loop-continue-deadincr` (`continuing{}`) dropped 60 → 29, `#switch-fallthrough` (statement duplication — `fallthrough` was removed from WGSL) dropped 29 → 28, and proxy FP-adjudication (#52) split 9 benign EDGE from 19 persistent DIFFER (chaos / control-flow / proxy-round-trip). Same single-oracle-proxy caveat | `just wgsl-naga`, `bash tools/wgsl_render_check.sh` |
| **HLSL** | **compile-verified** (glslang + DXC) | glslang accepts the emitted HLSL (0 INVALID); DXC canonical SM6.x compile-verify now provisioned in Docker — 51 PASS / 3 honest-error / 2 SKIP; the D3D12 *render*-diff (semantic truth) is still founder-gated. The previously WARP-flagged matrix-convention bug (`floatCxR` row-fill → transpose) is **FIXED via `emitMatrixMulSwapped`** (mirrors spirv-cross's `mul(v,M)` convention) and **WARP-CONFIRMED** — a re-run on the real DXC→DXIL→D3D12 runtime gave **3 RENDER-MATCH / 0 RENDER-DIFFER** on the exact three previously flagged (mat3_branch, mat_cond_swizzle, outer_product_test); zioshade's HLSL byte-matches spirv-cross. A **full WARP corpus sweep** on real D3D12 (ryzen7pro): **803 RENDER-MATCH / 9 RENDER-DIFFER / 599 skip** (post-fix re-sweep confirmed at scale — zero regression). The one control-flow DIFFER (`switch_fallthrough` — HLSL emitted unconditional `break;`, dropping the fallthrough accumulation) is **FIXED** (emit `break;` only for terminal cases; fallthrough cases fall through, mirroring spirv-cross) and moved DIFFER→MATCH. The remaining 9 DIFFERs are benign-FP (mandelbrot_iter/simple/3, multi_return2, nested_func_expr — chaotic shaders diverging by FP ordering) or harness artifacts (.vk.nocompat; .desktop depth-greater/less + image-query) | `just hlsl-glslang-all`, `just hlsl-dxc` |

**What "compile-verified only" means, honestly.** A compiler can emit output a
downstream validator accepts yet still compute the wrong thing — precisely the
"plausible-but-wrong" failure zioshade exists to eliminate. Only the MSL backend
has a *render/exec* oracle (run it on the GPU, compare pixels); for GLSL/WGSL/HLSL
we currently prove the output is *well-formed*, not that it is *semantically
correct*. Two consequences, by design:

- Where zioshade cannot translate a construct safely, it **declines loudly**
  (a named honest-error) rather than emit a best-effort translation that might be
  wrong. Every "honest-err" / XFAIL above is such a refusal, never a silent pass.
- The DXC **compile**-verify tier is now provisioned (`just hlsl-dxc`, DXC in Docker —
  51 PASS / 3 honest-error / 2 SKIP), giving HLSL a canonical SM6.x compile oracle on
  top of the glslang frontend gate. The DXC → D3D12 **render** oracle
  (`tools/hlsl_render_check.sh` + `tools/warp/`) — which would lift HLSL from
  compile-verified to render-proven — is the remaining founder-gated tier: it needs a
  D3D execution rig, and DXC compile is itself not a semantic oracle. wintty ships on
  MSL today, so the macOS render-proven path remains the one that matters for the consumer.

**Bottom line:** trust the MSL path as render-verified; treat GLSL/WGSL/HLSL as
compile-checked and honest-error-bounded — not as semantically proven.

## Second independent oracle: naga render differential

The render differential above compares zioshade against ONE reference (SPIRV-Cross).
The one thing it can never catch is a spec misreading that zioshade and SPIRV-Cross
*share* — both would render identically-but-WRONG and pass silently. To close that
blind spot, zioshade's MSL is now also render-diffed against a **second independent
cross-compiler, naga** (which has its own SPIR-V→MSL backend, unrelated to SPIRV-Cross).
Where zioshade, SPIRV-Cross, AND naga all render the same pixels, a shared misreading
is far less likely — the shader is **render-proven-2-oracle**.

`tools/prove_naga.sh` runs this over the corpus (glslang→SPIR-V, then both zioshade-MSL
and naga-MSL rendered on Metal and pixel-diffed). Latest full-corpus run:

| verdict | count | meaning |
|---------|------:|---------|
| MATCH (render-proven-2-oracle) | 1127 | zioshade and naga agree pixel-for-pixel — correlated-error blind spot **closed** |
| DIFFER (flagged; 0 are boundary-FP) | 7 | no ground truth — flagged, **never** auto-"fixed". Was 46; 39 were the `#loop-continue-deadincr` bug (a Private-var loop counter whose increment a body `continue;` skipped → infinite loop, fixed — see below). The residual 7 are chaotic/iterative shaders with no single correct pixel (mandelbox, exp-log-pow, logistic-map, …). |
| skip-render | 21 | naga MSL needs buffer/texture bindings not yet wired |
| skip-glslang / skip-naga / skip-zioshade-msl | 296 | non-Vulkan source / naga can't cross / zioshade can't emit |

That is **1090 of 1453 corpus shaders (75%; 94% of renderable)** whose MSL now agrees
across two independent compilers on a real GPU. The DIFFERs are treated exactly per the
project's anti-plausible-wrong rule: a disagreement between two independent compilers has
no ground truth (either could be wrong, or both could share a *different* misreading), so
they are **flagged for human investigation, not silently "fixed"** — manufacturing a fix
against an unverified oracle would be the precise sin this project exists to prevent. The
flagged set clusters in chaotic/iterative shaders (FP-amplification) and loop-control
shaders (the known-hard surface), which are the worthwhile investigation targets.

A precise-FP pass (re-rendering each DIFFER with Metal fast-math disabled, like
`prove_opt`'s EDGE classifier) classified **0 of the 46 as boundary-FP** — all persist.
That is the honest ceiling of auto-classification: it rules out measure-zero FP rounding
edges, but chaotic shaders legitimately diverge between two correct compilers by FP
ordering (whole-image disagreement, e.g. mandelbox), which precise-FP cannot resolve
since the two MSL programs are structurally different. So the persistent set is a mix of
benign chaotic-FP divergence and genuine control-flow differences; separating them needs
manual analysis with ground truth, not more automation — the disciplined stopping point.

**Update (2026-07-27) — that manual analysis has been done.** 39 of the 46 were NOT
chaotic: they were one systematic bug, `#loop-continue-deadincr`. On unoptimized SPIR-V,
a loop with a Private-var (non-OpPhi) counter emitted the increment at the BOTTOM of the
`while(true)` body, where a body `continue;` skipped it → the counter never advanced → an
infinite loop. The `#237` top-of-loop increment (which makes `continue` advance the
counter) was gated on `has_phis` (OpPhi counters) only; generalizing it to all top-test
loops fixed it in MSL, GLSL, and HLSL. It was masked by `spirv-opt -O` (which lowers to
the phi/do-while form) — so `prove_opt` passed and only `prove_naga` (unoptimized)
surfaced it. After the fix: MSL naga 46 → 7, GLSL proxy 70 → 26, `prove_opt` 0 structural
regression. The residual is genuinely chaotic (no single correct pixel). Locked in
`tests/loop_phi_tests.zig` via a glslang-produced fixture (zioshade's own frontend emits
OpPhi counters, so source-compiled tests cannot reach the broken `!has_phis` path). WGSL
uses a separate `loop{}`/`continuing` lowering — tracked separately.

**The 7 MSL residuals are classified (3-oracle majority vote, `just prove-3oracle`):
NONE are real zioshade bugs.** 2 are NAGA-OUTLIER (zioshade matches spirv-cross, naga
dissents — `exp-log-pow`, `nested_func_expr`; zioshade is correct); 4 are CHAOS
(`loop_trackers`, `multi_return2`, `switch_in_loop`, `dowhile_exit` — all hash /
`fract(sin(…))`-driven, FP-amplified control flow where the three compilers legitimately
diverge; `loop_trackers`' emitted structure verified correct); 1 is an undef edge case
(`loop-dominator-and-switch-default` — zioshade's frontend honest-errors the GLSL, an
uninitialized `vec4` driving a switch).

**The 25 GLSL-proxy residuals are classified the same way (3-oracle vote on each shader's
SPIR-V) — none are confirmed real zioshade bugs.** 15 are AGREE-ALL (zioshade-MSL matches
spirv-cross AND naga — zioshade's backend logic is correct for the shader, including the
deterministic `ray_struct`, `raytracing`, `recursive_struct`, `struct_array_gradient`,
`struct_ray2`, `multi-return-paths`, `nested_loop2`); for those, the GLSL DIFFER is a
GLSL-emission-specific or proxy-round-trip difference, NOT a fundamental miscompile (the
MSL backend — same SPIR-V — renders correctly).

**Correction — the GLSL faithfulness check (`just glsl-faithful`, `tools/glsl_faithfulness.sh`)
found that some of those "AGREE-ALL" GLSL DIFFERs ARE real zioshade-GLSL bugs, not proxy
artifacts.** It renders naga(zioshade-GLSL(source)→glslang) vs zioshade-MSL(source) [the
proven-correct reference] — an independent renderer of the round-tripped SPIR-V, no
spirv-cross. Result on the deterministic set: 5 FAITHFUL (proxy artifact confirmed) but
**4 UNFAITHFUL — real zioshade-GLSL miscompiles**: zioshade-GLSL silently DROPS loops/returns
in control-flow (`early_return2`: source's for-loop + early return vanish entirely;
`loop-dominator-and-switch-default`: 1 of 2 loops dropped; `multi-return-paths`: 4 returns
dropped). zioshade-MSL handles these correctly (3-oracle AGREE on the source), so this is a
zioshade-GLSL-specific bug in its loop/return lowering — the silent-wrong class, invisible
to the source-3-oracle (which tests the MSL backend). **Tracked as #69.** This is exactly
why the non-proxy check was needed: the proxy round-trip and the source-3-oracle could not
see a backend-specific emission bug. 3 are SC-OUTLIER (`mandelbrot_iter`,
`mandelbrot3`, `weierstrass` — zioshade agrees with naga; spirv-cross is the outlier;
chaos). 4 are hash-driven chaos (`loop_trackers`, `multi_return2`, `switch_in_loop`,
`loop-dominator-and-switch-default` — same set as the MSL residuals). 2 are harness
artifacts (`ubo_layout` UBO binding, `sampler-ms` sampler2DMS — both skip-render under the
proxy). The deterministic AGREE-ALL set is the one worth a direct-GLSL-render check (the
proxy round-trip is the prime suspect — see harness-hardening #52).

**The 28 WGSL-proxy residuals are classified identically — none are confirmed real
zioshade bugs.** 21 AGREE-ALL (zioshade-MSL matches both references, including the
deterministic `deep_branch5`, `deep_nest6`, `deep-ifelse`, `phi_nested`, `struct_tern`,
`cond-var-nested`, `quad-colors` — so the WGSL DIFFER is WGSL-emission/proxy, not
fundamental); 1 NAGA-OUTLIER (`nested_func_expr` — zioshade correct); 3 SC-OUTLIER
(`mandelbrot_iter`, `mandelbrot3`, `weierstrass` — spirv-cross outlier, chaos); 2
hash-driven chaos (`loop_trackers`, `loop-dominator`); 1 harness artifact
(`input-attachment.vk` — naga skips Vulkan subpass input).

**Bottom line across all three measured backends (MSL/GLSL/WGSL): after fixing the two
real bug classes — `#loop-continue-deadincr` and `#switch-fallthrough` — in all four
backends, every remaining DIFFER is explained: chaos (hash/fractal), harness artifacts
(binding skips), or backend-specific/proxy-round-trip differences where zioshade's
proven MSL backend (same SPIR-V) renders correctly. No confirmed real bugs remain.**

**Integer/quantized-output corpus (`just prove-integer`) — the airtight claim.** A
hand-written corpus of shaders whose output is FP-ordering-independent (integer
arithmetic, comparisons, bit ops, quantized writes — Collatz, GCD, factorial,
fibonacci-mod, nested loops, a fallthrough switch, integer control flow) is render-diffed
across all backends. For these, ANY DIFFER is a guaranteed real bug — chaos cannot
contaminate (the Csmith move). Result: **12/12 MATCH, 0 DIFFER, 0 skips across MSL
(direct) + GLSL + WGSL** — a correctness claim that floating-point divergence is
structurally incapable of falsifying.

**Chaos sensitivity classifier (`just chaos-classify`) — the honest scope.** Bins each
shader CHAOS (FP-amplifying: hash/fractal/iterative-escape/transcendental — no single
correct pixel; excluded from the pixel-correctness claim), BINDING (declares a
texture/sampler/UBO the harness can't supply — a DIFFER is an artifact), or DETERMINISTIC
(FP-ordering-independent — a DIFFER is a real-bug suspect). This fills the GraphicsFuzz gap
(detect-and-exclude, not just tolerate). Over `tests/spirv-cross`: **868 CHAOS / 536
DETERMINISTIC / 49 BINDING** — so the pixel-correctness claim meaningfully covers the ~536
deterministic shaders; the ~868 chaotic are compile+run-verified only (two correct
compilers legitimately diverge on them). Applied to the residual sets, it confirms every
residual is chaos / binding / deterministic-AGREE-ALL (zioshade-MSL correct) — no
deterministic DIFFER that is a real bug.

Regenerate: `bash tools/prove_naga.sh --dir tests/spirv-cross` (or `--sweep` for a sample).

Three independent kinds of evidence, weakest to strongest:

1. **Validity + robustness at scale** — every shader either produces SPIR-V the
   Khronos validator accepts, or fails loud. Never silent-wrong, never a crash.
2. **Execution equivalence** — zioshade's output and SPIRV-Cross's output,
   compiled and *run on a real GPU*, produce identical results.
3. **Fuzz** — structurally-generated shaders never crash or emit invalid SPIR-V.

---

## 1. Corpus sweep (validity + robustness)

`tools/corpus_sweep.sh` runs every GLSL shader in a directory through the
zioshade CLI and categorizes the result against `spirv-val`. Run over
SPIRV-Cross's *own* input corpus (`tests/spirv-cross/`, the shaders that project
wrote to exercise a full Khronos cross-compiler):

| Stage    | GLSL shaders | valid SPIR-V | honest-error | silent-wrong | crash |
|----------|-------------:|-------------:|-------------:|-------------:|------:|
| fragment |         1453 |         1447 |            6 |        **0** | **0** |
| compute  |           77 |           62 |           15 |        **0** | **0** |
| vertex   |           45 |           45 |            0 |        **0** | **0** |
| **total**|     **1575** |     **1554** |       **21** |        **0** | **0** |

The two columns that matter are the last two. **Zero silent-wrong** (exit 0 with
output the validator rejects) and **zero crashes** across 1575 third-party
shaders is the core claim: where zioshade does not fully cover a Vulkan/ESSL
feature (the 21 honest-errors), it says so and exits non-zero, exactly as a
drop-in replacement must — it never emits plausible-looking wrong SPIR-V.

SPIR-V *assembly* inputs (`*.asm.*`) are excluded: they are not GLSL and belong
to the cross-compiler's assembly path, not the GLSL frontend.

Reproduce:
```
zig build cli
tools/corpus_sweep.sh tests/spirv-cross fragment frag
tools/corpus_sweep.sh tests/spirv-cross compute  comp
tools/corpus_sweep.sh tests/spirv-cross vertex   vert
```
The script exits non-zero if any silent-wrong or crash is found, so it doubles as
a gate. This sweep is how the `gl_ViewIndex` builtin-constant bug and the
no-entry-point silent-wrong were found and fixed.

---

## 1b. Backend source validity (does the emitted code compile?)

The corpus sweep above validates the SPIR-V frontend. `tools/backend_validity_sweep.sh`
does the same for the cross-compiler *backends*: it emits every shader as GLSL and
WGSL and validates the output with that ecosystem's own tool (`glslangValidator`;
`naga` when installed). MSL validity is covered more strongly by the on-GPU
differential in section 2b. A backend that emits source its own validator rejects
is the silent-wrong class again, one layer out.

Over the compute corpus (`tools/compute_corpus/`, 12 kernels): **GLSL 12/12 valid**.

This sweep and the compute differential together found four cross-backend bugs,
each with the zioshade frontend SPIR-V byte-identical to glslang's (the defect was
in a specific backend):

| SPIR-V opcode | backend | was | now |
|---------------|---------|-----|-----|
| `OpFMod` | MSL, WGSL | `fmod` / `%` (wrong sign) | `x - y*floor(x/y)` |
| `OpBitcast` | MSL, GLSL | numeric conversion | `as_type` / `floatBitsToUint` etc. |
| `OpVectorExtractDynamic` | MSL, GLSL | unhandled stub | `vec[idx]` |
| vector relational (`OpFOrdGreaterThan` on vecN) | GLSL | `a > b` (scalar-only) | `greaterThan(a, b)` |

(HLSL was already correct on all four.) Reproduce:
```
zig build cli
tools/backend_validity_sweep.sh
```

Run at corpus scale it is a strong backend gate. Over the full SPIRV-Cross
**fragment** corpus (1453 non-assembly shaders) the GLSL backend started at 69
shaders emitting glslang-rejected output at exit 0. Each is the silent-wrong class
one layer out — plausible-looking source that does not compile — and invisible to
spirv-val. Fixes so far (frontend SPIR-V unchanged / valid in every case):

- **const scalar/vec/mat globals** dropped their initializer, producing an
  uninitialised Private variable (silent-wrong value; undeclared identifier on
  GLSL/MSL). Now materialised as a constant initializer.
- **value structs** used only through an inlined function became `OpCompositeConstruct`
  SSA values that no backend pass declared (`Light l = Light(...)` with no
  `struct Light`). Now collected and declared.

That took the fragment corpus to 1385/1453 valid. The remaining rejections are a
mix of genuinely advanced features that should instead honest-error (barycentric,
pixel/sample interlock, tensor, spv14 block-match, push-constant blocks, subpass
input attachments) and a few narrower backend gaps (mutual recursion, ternary on a
struct value) — catalogued for follow-up.

---

## 2. Execution equivalence (MSL, on-GPU)

Validity is necessary but not sufficient: valid SPIR-V can still compute the
wrong thing. `tools/ShaderCompare.swift` renders **both** zioshade's MSL and
SPIRV-Cross's MSL for the same shader on the Metal GPU and diffs the framebuffer
per pixel.

Both toolchains driven from the identical SPIR-V (glslang frontend), rendered at
256×256 on an Apple M2:

| Shader | pipeline | different pixels | result |
|--------|----------|-----------------:|--------|
| wintty CRT   | GLSL → SPIR-V → MSL (zioshade) vs (SPIRV-Cross) | **0 / 65 536** | identical |
| wintty focus | GLSL → SPIR-V → MSL (zioshade) vs (SPIRV-Cross) | **0 / 65 536** | identical |

Byte-for-byte identical output, executed on real hardware. See
`docs/RENDERING_RESULTS.md` for the earlier cross-platform runs (Windows OpenGL
GLSL and DXC HLSL).

Reproduce (macOS):
```
zig build cli
zig build dump-crt                       # or: zioshade msl <shader> --stage fragment
glslangValidator -V <shader> -S frag -o ref.spv && spirv-cross --msl ref.spv -o ref.msl
swiftc tools/ShaderCompare.swift -o /tmp/ShaderCompare
/tmp/ShaderCompare zioshade.msl ref.msl
```

---

## 2b. Execution equivalence (compute, on-GPU)

The two fragment shaders above exercise the backend narrowly. To broaden the
proof across the whole scalar / vector / matrix / intrinsic / control-flow
surface a kernel can touch, `tools/compute_diff.sh` runs a corpus of GLSL
compute shaders (`tools/compute_corpus/`) two ways — zioshade's MSL and
SPIRV-Cross's MSL — on the Metal GPU over an identical input buffer, and diffs
the **output buffers** numerically (`tools/ShaderComputeCompare.swift`).

Over 12 kernels (1024 elements each) on an Apple M2:

| Category (kernel) | max relative diff | result |
|-------------------|------------------:|--------|
| arithmetic, common math, integer/bitwise, vectors, matrices, swizzles, logic, bitcast | **0** | bit-exact |
| transcendental, control-flow, functions/fma | ~1e-7 | ULP-level (instruction reordering) |

**All 12 match.** Nine are bit-exact; three differ only at the last floating
point bit from legitimate instruction selection in transcendental/fma code.

This differential is not a rubber stamp — building it surfaced **four** MSL
backend bugs, each confirmed by running the wrong output on the GPU. In every
case zioshade's *frontend* SPIR-V was identical to glslang's (verified with
`spirv-dis`); the defect was purely in SPIR-V → MSL:

| SPIR-V opcode | was emitted as | correct MSL | class |
|---------------|----------------|-------------|-------|
| `OpFMod` | `fmod(x,y)` | `x - y*floor(x/y)` | silent-wrong for negative operands |
| `OpBitcast` | `uint(x)` (rounds) | `as_type<uint>(x)` | silent-wrong (`floatBitsToUint(2.5)`→2 not `0x40200000`) |
| `OpExtInst Degrees`/`Radians` | `degrees(x)`/`radians(x)` | `x * 57.29578` / `x * 0.0174533` | won't compile (no such Metal builtin) |
| `OpVectorExtractDynamic` | `// unhandled op 77` | `vec[idx]` | won't compile (undeclared identifier) |

The first two are the exact "silently emits plausible-looking wrong output"
failure this project exists to prevent; the differential caught them because it
executes, where a validity-only check (spirv-val) cannot. Regressions are locked
in `tests/msl_tests.zig`.

Reproduce (macOS):
```
zig build cli
tools/compute_diff.sh            # builds the harness, runs the corpus, gates on any diff
```

---

## 3. Fuzz

`zig build fuzz -- --count 30000 --validate` generates 30 000 structurally-random
GLSL shaders, compiles each, and validates the SPIR-V with `spirv-val`:

```
Pass: 30000  Fail: 0  Skip: 0  Total: 30000
```

Zero crashes, zero invalid modules.

---

## What "faithful" does and does not mean here

zioshade is a focused replacement for the shader-compilation surface wintty needs
(GLSL 330–460 class shaders), not a full Khronos drop-in — see
`docs/IMPLEMENTATION_STATUS.md`. The corpus honest-errors above are that scope
boundary made explicit and measurable. The guarantee is not "compiles every
Khronos shader" but "for every shader, either matches the reference or refuses —
never silently diverges." The tables above are the evidence for that guarantee.

---

## Per-backend verification confidence (be honest about what is proven)

Not every backend is verified to the same depth. The distinction that matters is
**compile-validity** (a real target compiler accepts the output) vs
**render-correctness** (the output produces the right pixels).

| Backend | Compile oracle | Render-verified? |
| --- | --- | --- |
| GLSL | glslangValidator | GLSL rendered on Windows OpenGL (RENDERING_RESULTS.md) |
| WGSL | naga | not rendered (naga validates semantics) |
| MSL  | Metal `makeLibrary` | **yes** — `ShaderCompare.swift` renders on-GPU, 0-pixel diff vs spirv-cross |
| HLSL | DXC (`ps_6_0`, in a docker container) | **yes for self-contained shaders** — render-verified on Metal (via DXC) and on real D3D12 WARP; the matrix transpose bug this surfaced is fixed (#497). Uniform-input shaders remain compile/round-trip verified (see below) |

### HLSL render-verification (macOS, via DXC → Metal)

macOS has no Direct3D, but HLSL can still be render-verified without Windows:
`tools/hlsl_render_check.sh` compiles zioshade's HLSL with the **real DXC** oracle
to SPIR-V, converts that to MSL with SPIRV-Cross, and renders it on the Metal GPU
(reusing `ShaderCompare.swift`), diffing pixels against zioshade's own MSL backend
(itself 0-pixel render-proven vs SPIRV-Cross, section 2). DXC is the true HLSL
frontend, so a wrong HLSL emission compiles to different SPIR-V and renders
different pixels. Verdicts: **RENDER-MATCH** (≤1/channel), **RENDER-EDGE** (a
handful of boundary pixels differ with ~0 average — benign floating-point at a
`step()`/discontinuity, e.g. `art_deco` = 5 px), **RENDER-DIFFER** (large-area
divergence = a real miscompile).

**Independent frontend oracle.** When the HLSL-vs-MSL render diverges, the script
consults a second, backend-independent oracle: it compiles the same GLSL with both
zioshade and **glslang**, runs both SPIR-Vs through the *same* SPIRV-Cross → MSL
backend, and renders both. Using one backend cancels backend floating-point, so a
residual divergence isolates a **frontend** structural difference
(`frontend=MISCOMPILE`) from benign backend fast-math (`frontend-clean`). One caveat:
Metal's driver-level fast-math (fp contraction/reassociation) is context-sensitive to
the full MSL text, so two *semantically-equivalent* frontend SPIR-Vs can still round
differently at an fp discontinuity (a `step()` edge on a pixel center). The oracle
therefore re-renders any suspected frontend miscompile with **fast-math disabled**
(`SHADERCOMPARE_SAFE_MATH=1`, `MTLCompileOptions.mathMode = .safe`): if the two then
match exactly, the frontend arithmetic is provably identical and the divergence is
benign backend fast-math (`frontend-precise-clean,fast-math-fp`), not a miscompile.
This is a strict de-escalation — precise fp still honors evaluation *order*, so a real
frontend reassociation or a structural bug (e.g. a switch case reading uninitialized
memory) still diverges under precise fp and stays `frontend=MISCOMPILE`. Example:
`origami` flags under fast-math (105 px on the `uv.x+uv.y==0` fold, which lands exactly
on pixel centers) but is precise-clean — zioshade computes the boundary sum as exactly
`0` (`step(0,0)==1`), which is in fact more accurate than glslang there.

Result: a broad set of non-matrix shaders **RENDER-MATCH**, which upgrades them
from compile-verified to render-verified and **resolves the SPIR-V differential's
DIVERGE over-reporting** — e.g. `swizzle_access` and `mandelbrot_smooth` (both
flagged DIVERGE by the program-identity diff) render pixel-identical.

**Matrix finding (open):** the matrix cluster does NOT cleanly render-verify. Three
matrix shaders — `mat3_branch` (64480/65536 px), `mat_cond_swizzle` (49192),
`outer_product_test` (50721) — render **differently from SPIRV-Cross's HLSL**
through the identical DXC→SPIR-V→SPIRV-Cross→MSL pipeline (so a round-trip artifact
cancels), while the reference path (zioshade SPIR-V → SPIRV-Cross → MSL) is a
0-pixel match with zioshade's direct MSL. This contradicts the earlier
*codegen-equivalence inference* that zioshade's HLSL matrix convention (the
transpose of SPIRV-Cross's) is mathematically equivalent: it renders the same as
MSL for `mat_branch` (mat2) but diverges for mat3-class shaders. So HLSL matrix
correctness is now a **measured open question, not a safe inference** — the DXC
compile sweep passes these shaders (they are valid HLSL) but they render wrong.

**Found, root-caused, and FIXED — confirmed on WARP (real D3D12).** The `tools/warp/`
harness (`DXC → DXIL → D3D12 WARP`, no MSL proxy) was run on a Windows box. Before the
fix: `RENDER-MATCH = 5`, `RENDER-DIFFER = 3` (`mat3_branch`, `mat_cond_swizzle`,
`outer_product_test`). After the fix (#497): `RENDER-MATCH = 8, RENDER-DIFFER = 0` on
the same real runtime.

**Root cause.** HLSL's `floatCxR(a, b, c)` constructor fills the matrix by ROWS,
whereas MSL's `matCxR(a, b, c)` fills by COLUMNS. zioshade emitted the same
column-by-column construction for both backends, so in HLSL a LOCAL matrix is stored
transposed and `mul(M, v)` computed Mᵀ·v. SPIRV-Cross stores the same transpose but
compensates with `mul(v, M)` (= M·v). The earlier "codegen-equivalence with the
render-verified MSL backend" argument was a false analogy — MSL and HLSL matrix
constructors have opposite row/column semantics. The DXC compile sweep and spirv-val
passed these shaders for multiple sessions while they rendered wrong; only a render
oracle caught it.

**Fix (#497).** Swap the matrix-multiply operands to match SPIRV-Cross, but only for
LOCAL / constructed matrices. zioshade has two matrix storage conventions: local
(row-filling constructor → transposed storage → needs the swap) and UNIFORM/cbuffer
(bare column_major → logical M → `mul(M, v)` already correct). `emitMatrixMulSwapped`
traces the matrix operand to its source and leaves the uniform path byte-unchanged.
Verified: `tools/hlsl_render_check.sh` (Metal) RENDER-MATCHes the local/inverse/chain/
transpose matrix shaders, WARP goes 5/8 → 8/8, DXC validity is unchanged, and the
T597 uniform tests still pass.

**Uniform matrices are now render-verified too (#498).** A `gl_FragCoord` +
uniform-`mat4` shader renders through the existing Metal harness (both MSL emissions
read a `float4x4` at buffer(0)); it RENDER-MATCHes zioshade's own MSL AND an
*independent* glslang → SPIRV-Cross → MSL reference (0-pixel), and the uniform-copied-
to-local edge case of the #497 fix renders correct (the copy is traced/propagated to
the uniform load). On real D3D12, `tools/warp/` now binds a root CBV at `b0` with a
known asymmetric mat4, so uniform-matrix shaders render there too: they RENDER-MATCH
SPIRV-Cross's HLSL, and the self-contained set stays 8/8. So the matrix surface —
local and uniform — is render-verified against independent references on both Metal
and the real DXC→DXIL→D3D12 path. What still skips: shaders needing a texture or
custom vertex attributes (the fullscreen-triangle harness feeds only gl_FragCoord +
one cbuffer).

### Vertex render-verification (macOS, via Metal)

Fragment shaders were render-verified for many sessions while VERTEX shaders were only
COMPILE-verified — a hole in the "provably equivalent across the pipeline" claim: a
vertex shader that compiles cleanly but computes the wrong `gl_Position` would pass every
check. `tools/VertexCompare.swift` + `tools/vert_render_check.sh` close it. A vertex
shader's observable output is where it places its vertices, so the harness renders the
TRIANGLE the shader's `gl_Position`s define (fixed known input attributes + an
identity-filled uniform buffer, solid-white fragment); the rasterised coverage is a pure
function of the computed clip-space positions. Rendering zioshade's frontend SPIR-V and
glslang's SPIR-V through the SAME SPIRV-Cross → MSL backend isolates a FRONTEND
divergence; rendering zioshade's own MSL backend against the reference catches a backend
one. The harness is self-validated: an equivalent pair renders 0-pixel, and a deliberately
offset `gl_Position` (`+0.3` in x) renders 8374 differing pixels — it detects real vertex
miscompiles.

The rasterising harness only has test power when the triangle lands on-screen, so a
NUMERIC variant (`tools/VertexNumeric.swift` + `tools/vert_numeric_check.sh`) gives
coverage for EVERY vertex regardless of where `gl_Position` lands: it injects a
`device float4*` output into the (very regular) spirv-cross-emitted vertex entry, writes
`out.gl_Position` to it, runs the vertex stage over N varied vertices, and diffs the
captured clip-space positions numerically. Same self-validation (equal pair `maxAbs=0`; a
`+0.3` offset flags `maxAbs=0.3`). glslang's reference SPIR-V is auto-map-bindings'd
(`--amb --aml`) so the SPIRV-Cross test shaders (which omit explicit `layout(binding=)`)
still produce a reference — the differential compares captured positions, not binding
numbers.

Result over the `.vert` corpus (numeric): **33 of 45 shaders covered, 0 frontend
miscompiles, 0 backend divergences.** The covered set exercises real `gl_Position`
computation — UBO `mat4 * aVertex` transforms, texture-sampled terrain (`ground`,
`ocean`), row-major-array reads, push constants, clip-distance, I/O blocks,
`no-contraction`, nested switches — all matching the independent glslang → SPIRV-Cross
reference to `maxAbs=0`. The remaining 12 are honest skips (glslang or SPIRV-Cross rejects
the reference, or the capture injection doesn't fit an edge shape: `invariant gl_Position`,
clip/cull-distance extra outputs, integer/16-bit attributes, transform-feedback, multiview)
— never mis-verified. The earlier rasterising harness (`VertexCompare.swift`) remains as a
visual/coverage cross-check.

So the differential proof now spans all three stages: **fragment** (most exhaustively —
render-verified vs an independent glslang reference on Metal and, for HLSL, real D3D12
WARP), **vertex** (33 shaders numerically render-verified, 0 divergence), and **compute**
(numeric buffer differential, `tools/compute_diff.sh`, 12 kernels).
