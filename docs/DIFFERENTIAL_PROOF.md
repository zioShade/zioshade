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
`tools/hlsl_render_check.sh` + `tools/warp/`). A representative run: **81 shaders verified,
0 divergences.** Honest scope: the corpus is SPIRV-Cross's own test suite — a strong
differential oracle, not a guarantee about arbitrary real-world shaders — and every
uncovered shader is reported as an explicit skip, never counted as a pass.

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
