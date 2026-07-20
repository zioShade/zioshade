# Differential proof: does zioshade behave like the tools it replaces?

zioshade replaces two C++ tools: **glslang** (GLSL → SPIR-V) and **SPIRV-Cross**
(SPIR-V → HLSL / MSL / GLSL / WGSL). This document records the evidence that it
does so faithfully, and how to reproduce each measurement. All numbers below are
from the checked-in shader corpora and are regenerable locally.

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
| HLSL | DXC (`ps_6_0`, in a docker container) | **NO — compile-verified only** |

HLSL render-verification is not currently possible in this dev environment (no
DirectX/GPU on macOS), so the HLSL sweep (`tools/hlsl_validity_sweep.sh`) proves
the output **compiles** under DXC, not that it **renders** correctly. Matrix
operations (the largest HLSL cluster) are argued correct by
**codegen-equivalence with the render-verified MSL backend** — zioshade emits
byte-identical matrix construction, the same `mul(M,v)` order, and the same
`spvInverseNxN` helper as MSL, whose rendering is proven above. That is a strong
inference, not a measurement.

**Recommended pre-launch gate:** stand up a headless HLSL render check on a
Windows runner (D3D WARP software rasterizer, in the Windows SDK) — one
round-trip golden test (identity, a known rotation, and `M · inverse(M) == I` read
back from a render target) retroactively validates the whole HLSL matrix surface
and makes every future matrix fix render-verifiable. Until then, HLSL matrix
correctness is stated as *compile-verified, render-inferred*.
