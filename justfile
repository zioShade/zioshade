# zioshade — CI-equivalent recipes
# All recipes use `mise exec --` to ensure Zig 0.15.2 is used.
# `just ci` runs the same job set as the GitHub workflow, but on one OS and one
# toolchain (this machine, Zig 0.15.2). CI runs that set across 3 OSes and both
# 0.15.2 and 0.16, so a green `just ci` is a necessary condition for a green CI
# run, not a sufficient one: platform- and version-specific failures only show
# up on the hosted runners. `just ci-full` adds the gates that need local
# oracles or hardware (DXC, Metal, spirv-cross, the render proofs), which the
# hosted runners cannot provide.

set dotenv-load := false

# zig wrapper — ensures Zig 0.15.2 via mise
zig := "mise exec -- zig"
# DXC (HLSL oracle). Defaults to tools/dxc — the Docker wrapper over the pinned DXC
# image (run `just dxc-image` once first). Override with $ZIOSHADE_DXC or
# `just dxc="C:/path/to/dxc.exe" hlsl-dxc` for a local DXC on PATH.
dxc := env_var_or_default("ZIOSHADE_DXC", "tools/dxc")

# ── default ──────────────────────────────────────────────────────────

default: test

# ── build ────────────────────────────────────────────────────────────

# build the library (debug)
build:
    {{zig}} build

# build the CLI (mirrors the build-test CI job)
cli:
    {{zig}} build cli

# build the examples (mirrors the build-test CI job)
examples:
    {{zig}} build examples

# build in release mode
release:
    {{zig}} build -Doptimize=ReleaseFast

# ── tests ────────────────────────────────────────────────────────────

# run all unit tests (lexer, parser, semantic, codegen, spirv, ir, etc.)
test:
    {{zig}} build test --summary all

# run HLSL backend tests (751 tests)
test-hlsl:
    {{zig}} build test-hlsl --summary all

# run SPIR-V conformance tests against spirv-val (requires Vulkan SDK)
test-conformance:
    {{zig}} build conformance --summary all

# list analyzer false-positive candidates (strict vs tolerate compile)
enumerate-fp:
    {{zig}} build enumerate-fp --summary all

# --min-pass pins the current corpus size so a vanished fixture directory cannot report a
# green gate over an empty run. Keep this floor in sync with .github/workflows/ci.yml.
#
# continuous strict-gate: verify no curated-valid fixtures are rejected (FP regression check)
strict-gate:
    {{zig}} build strict-gate --summary all -- --min-pass=2108

# ── backend oracle differentials ─────────────────────────────────────
# Every backend output is checked against its reference oracle:
#   SPIR-V → spirv-val   (conformance)        HLSL → dxc            (hlsl-dxc)
#   GLSL/HLSL/MSL structural → spirv-cross    (test-cross-compare)
#   WGSL → naga          (wgsl-naga / test-realworld)
#   MSL silent-wrong invariants               (msl-lint)

# cross-compiler structural differential: zioshade output vs SPIRV-Cross
test-cross-compare:
    {{zig}} build test-cross-compare --summary all

# validate zioshade WGSL output against naga (real-world shader corpus)
test-realworld:
    {{zig}} build test-realworld --summary all

# INTERIM tier-1 HLSL validity gate: cross-compile the SPIR-V corpus to HLSL and
# parse/semantic-check it with glslangValidator's HLSL frontend (-D, -V). Needs no
# Docker/DXC, so it is the always-on analog of wgsl-nana / msl-metal / glsl-glslang
# and catches the silent-wrong class on SM5-era shaders (wintty's profile).
# NON-CANONICAL: glslang's HLSL frontend is a deprecation-track parser (glslang #4210),
# not DXC/fxc — pin the glslang version; the gold standard stays `hlsl-dxc`. Exits
# nonzero on any INVALID (glslang-rejected) emission; oracle segfaults and frontend
# honest-errors are counted separately. See tools/hlsl_glslang_sweep.sh.
hlsl-glslang:
    tools/hlsl_glslang_sweep.sh

# All three stages (fragment + vertex + compute) of the interim HLSL gate. Each stage
# has its own known-deferred baseline; exits nonzero on any NEW regression in any stage.
# Vertex/compute were a blind spot (the gate used to run fragment-only) — this runs them.
hlsl-glslang-all:
    tools/hlsl_glslang_sweep.sh tests/spirv-cross fragment frag
    tools/hlsl_glslang_sweep.sh tests/spirv-cross vertex vert
    tools/hlsl_glslang_sweep.sh tests/spirv-cross compute comp

# validate zioshade HLSL output against DXC over the SPIR-V corpus (stage-aware:
# vs/ps/cs/ms profiles auto-selected from each module's execution model). This
# is the HLSL analog of `wgsl-naga` / `msl-lint` — dxc is the real HLSL oracle.
# Reports per-stage PASS/FAIL/SKIP. Requires dxc (override the `dxc` variable).
#
# Baseline at SM 6.0: ZERO unexplained divergences. The 4 known FAILs are all
# DXC/D3D constraints on otherwise-correct zioshade HLSL, NOT zioshade bugs:
#   * barycentric-{khr,khr-io-block,nv}: `SV_Barycentrics` requires ps_6_1
#     (correct semantic; this gate compiles at 6.0).
#   * complex-expression-in-access-chain: a structured-buffer element exceeds
#     DXC's hard 2048-byte element-size limit (16384 B); a D3D limit, not zioshade.
# Any NEW fail beyond these four is a real divergence to fix.
# build the pinned DXC Docker image (linux/amd64; Rosetta on Apple Silicon).
# Required once before `just hlsl-dxc` (the default tools/dxc wrapper uses it).
dxc-image:
    docker build --platform linux/amd64 -f tools/dxc.Dockerfile -t zioshade-dxc tools

hlsl-dxc:
    {{zig}} build test-dxc -- "{{dxc}}" tests/spirv_bins 60

# all backend oracle differentials in one gate (spirv-val + SPIRV-Cross + naga)
oracle-diff: test-conformance test-cross-compare test-realworld
    @echo ""
    @echo "Backend oracle differentials: ALL PASSED (spirv-val + SPIRV-Cross + naga)"

# ── render/execution differential proof (macOS + Metal, no Docker) ────
# One command reproduces the differential correctness proof across ALL THREE shader
# stages: zioshade's output is rendered/executed on the real Metal GPU alongside an
# independent glslang -> SPIRV-Cross reference and diffed (fragment = pixels, vertex =
# captured gl_Position, compute = output buffers). This catches the silent-wrong class
# that compile-only checks (spirv-val/dxc) cannot. Prints one honest report (verified /
# benign / divergences / skipped-with-reason) and exits nonzero on any real divergence,
# so it doubles as a regression gate. Fragment is sampled for speed; PROVE_FULL=1 runs
# the whole fragment corpus. See docs/DIFFERENTIAL_PROOF.md for scope and caveats.
prove:
    @bash tools/prove.sh

# Optimized-SPIR-V MSL BACKEND render-diff (spirv-opt -O → zioshade msl vs
# spirv-cross --msl → Metal render+diff). Complements `prove` (which tests the
# unoptimized FRONTEND): this reaches the control-flow/phi/merge/load-cache
# plausible-wrong classes that only surface on optimized SPIR-V. EVERY=N sets
# the corpus sample (default 25). See tools/prove_opt.sh.
prove-opt:
    @bash tools/prove_opt.sh --sweep

# every backend differential/validity gate in one honest per-backend confidence
# report (render-proven vs compile-verified). Additive orchestrator; delegates
# to the existing scripts without modifying them (`--list` prints the plan).
prove-all:
    @bash tools/prove_all.sh

# naga SECOND-oracle MSL render-diff: closes the single-oracle correlated-error blind
# spot (where zioshade + spirv-cross share a misreading). --dir runs the full corpus.
prove-naga:
    @bash tools/prove_naga.sh --dir tests/spirv-cross

# 3-oracle MSL MAJORITY VOTE (ground-truth classification of a naga DIFFER). Renders
# zioshade / spirv-cross / naga MSL on Metal and lets the majority rule: AGREE-ALL,
# NAGA-OUTLIER (z==spirv-cross, naga dissents — zioshade correct), SC-OUTLIER, or
# Z-DISAGREES-BOTH (chaos / real bug — chaos-probe target). spirv-cross is the render-
# proven reference, so "z agrees with spirv-cross" is decisive. Pass frags or --dir.
#   just prove-3oracle tests/spirv-cross/exp-log-pow.frag tests/spirv-cross/mandelbox.frag
prove-3oracle frags="--dir tests/spirv-cross":
    @bash tools/prove_3oracle.sh {{frags}}

# large-corpus WGSL<->naga differential: every conformance fixture -> WGSL -> naga.
# Reports naga PASS / REJECT (divergences to fix) / honest-unsupported. Slow
# (naga subprocess per fixture); run on demand, not in `ci`.
wgsl-naga:
    @bash tools/wgsl_naga_sweep.sh

# two-oracle WGSL validity sweep (r2d.1): every fixture -> zioshade WGSL, then validated
# by BOTH naga AND tint (Chrome's WGSL compiler, auto-downloaded). TINT-REJECT or
# NAGA-REJECT (one oracle accepts what the other rejects) are real bug leads. Report-only;
# run on demand, not in `ci`.
wgsl-tint:
    @bash tools/wgsl_tint_sweep.sh

# GLSL/WGSL render proxies: re-compile the backend's output to SPIR-V (glslang/naga) ->
# spirv-cross MSL -> render-diff on Metal vs the render-proven MSL_ref. MATCH = the
# backend's output is render-correct (as glslang/naga parse it); single-oracle proxy.
glsl-render:
    @bash tools/glsl_render_check.sh
wgsl-render:
    @bash tools/wgsl_render_check.sh

# Integer/quantized-output CORRECTNESS corpus: hand-written shaders whose output is
# FP-ordering-independent (integer arithmetic, comparisons, bit ops, quantized writes) —
# so ANY DIFFER is a guaranteed real bug (chaos cannot contaminate; the Csmith move). The
# airtight headline: 0 divergences across all backends. Exercises loops (Collatz, GCD,
# factorial, fibonacci-mod, nested), a fallthrough switch, and integer control flow.
#   just prove-integer
prove-integer:
    @bash tools/prove_naga.sh --dir tests/integer_corpus
    @bash tools/glsl_render_check.sh tests/integer_corpus
    @bash tools/wgsl_render_check.sh tests/integer_corpus

# Chaos sensitivity classifier (source-signature heuristic): bin a corpus's shaders as
# CHAOS (FP-amplifying — no single correct pixel; excluded from the pixel-correctness claim),
# BINDING (declares a texture/sampler/UBO the harness can't supply — a DIFFER is an artifact),
# or DETERMINISTIC (FP-ordering-independent — a DIFFER is a real-bug suspect). Fills the
# GraphicsFuzz gap (detect-and-exclude, not just tolerate). Gives the honest scope claim.
#   just chaos-classify                           # tests/spirv-cross corpus
#   just chaos-classify tests/integer_corpus      # expect all DETERMINISTIC
chaos-classify dir="tests/spirv-cross":
    @bash tools/chaos_classify.sh {{dir}}

# Unreachable-statement scan: does the emitted source contain a statement AFTER a
# statement-level break/continue/return/discard in the same block? If so the emitter
# wrote a terminator it should not have and silently dropped the rest of that block.
# The output still compiles, so no validity gate sees it, and structural-drop does not
# either (that counts loops and switches, not reachability). Found #599 (WGSL emitted a
# second unconditional break, orphaning 36 shaders' loop bodies) and #604 (a selection's
# merge treated as a trampoline, leaving graphicsfuzz_061's loop with no exit).
# GATED in `just ci` and in the structural-drop CI job since #614: 0/0/0/0 across both
# corpora once #610, #612 and #614 closed the three benign classes it used to report.
#   just unreachable-scan            # wgsl over both corpora
#   just unreachable-scan msl        # another backend
# All four backends, the form `just ci` runs. Exits nonzero on any unreachable statement.
unreachable-scan-all:
    @for be in msl glsl hlsl wgsl; do python3 tools/unreachable_scan.py zig-out/bin/zioshade $be tests/spirv-cross/*.frag tests/cts/graphicsfuzz/*.spv || exit 1; done

unreachable-scan backend="wgsl":
    @python3 tools/unreachable_scan.py zig-out/bin/zioshade {{backend}} tests/spirv-cross/*.frag tests/cts/graphicsfuzz/*.spv

# Structural-drop sweep, all four backends: does the emitted source still contain every
# loop and switch the INPUT SPIR-V requires? A drop is silent-wrong — the output compiles,
# it just skips control flow, so no validity gate can see it. Three signals: cross-backend
# dissent, the SPIR-V floor (single-iteration loops subtracted, since flattening a
# `do{}while(false)` structured goto is correct), and WGSL nested-selection switch-breaks.
# NOT YET A GATE: it currently reports 14 known GLSL drops (10 CTS, 4 spirv-cross) from the
# loop-in-switch-case bug, and 0 for MSL/HLSL/WGSL. It becomes a gate when GLSL is fixed or
# refuses. The 2026-07-28 count sweep certified MSL/GLSL/HLSL clean, but it compared against
# raw OpLoopMerge counts and ran only over tests/spirv-cross; it missed all fourteen.
#   just structural-drop                      # both corpora, all backends
#   just structural-drop cts msl,glsl         # scope it down
structural-drop corpus="both" backends="msl,glsl,hlsl,wgsl":
    @python3 tools/structural_drop_sweep.py --corpus {{corpus}} --backends {{backends}}

# GLSL faithfulness check (non-proxy ground truth for zioshade-GLSL). Renders naga(zioshade-
# GLSL(source)->glslang) vs zioshade-MSL(source) [the proven-correct reference] — an
# INDEPENDENT renderer of the round-tripped SPIR-V, no spirv-cross. MATCH => zioshade-GLSL
# is faithful (any proxy DIFFER is a spirv-cross artifact). DIFFER => zioshade-GLSL emits
# GLSL that compiles to a semantically different SPIR-V -> a REAL zioshade-GLSL bug.
# Found a real bug class this way (zioshade-GLSL drops loops/returns in control-flow —
# early_return2, loop-dominator-and-switch-default). Pass the frags to check.
glsl-faithful frags="tests/spirv-cross/early_return2.frag tests/spirv-cross/loop-dominator-and-switch-default.frag":
    @bash tools/glsl_faithfulness.sh {{frags}}

# Value-level silent-wrong sweep: glsl-faithful over EVERY pure-gl_FragCoord fragment
# (no uniform/texture/sampler decls — the artifact-free subset). A UNFAITHFUL hit is a
# real GLSL emission bug that compiles clean. Found #switch-break-vs-default-target
# (PR #596) after all compile-only gates had passed. NON-GATING (needs swiftc+naga and
# ~3 min); run it after any GLSL backend control-flow change.
glsl-faithful-sweep dir="tests/spirv-cross":
    @bash tools/glsl_faithful_sweep.sh {{dir}}

# WGSL faithfulness check (non-proxy, mirror of glsl-faithful). CAVEAT: confounded by the
# naga-wgsl-vs-glslang frontend difference (no clean WGSL source to compare against), so
# UNFAITHFUL is suggestive not decisive — verify directly or via a wgpu render.
wgsl-faithful frags="tests/spirv-cross/quad-colors.frag tests/spirv-cross/nested_if_deep3.frag":
    @bash tools/wgsl_faithfulness.sh {{frags}}

# large-corpus MSL silent-wrong INVARIANT sweep — the MSL analog of wgsl-naga.
# No Metal compiler runs on Windows, so instead of validating we assert
# zero-false-positive invariants every valid MSL must satisfy (e.g. a pointer
# param `device T* name` must never be accessed as `name.` — the silent-wrong
# class fixed in PR #129). Emits MSL for every fixture; exits non-zero on any
# violation. Run on demand. (Proven: reports 73 violations pre-#129, 0 after.)
msl-lint:
    @bash tools/msl_invariant_sweep.sh

# large-corpus MSL backend-validity sweep with the REAL Metal compiler — the
# compiler-grounded counterpart of msl-lint (which asserts heuristics for Windows,
# where no Metal compiler runs). Cross-compiles every shader in a corpus to MSL and
# compile-checks it via tools/MslCompileCheck.swift (MTLDevice.makeLibrary). Exits
# non-zero on any shader zioshade emits at exit 0 but Metal rejects (the silent-wrong
# class). macOS only; run on demand.
#   just msl-metal                                  # tests/spirv-cross fragments
#   just msl-metal tests/glslang-430 fragment frag
msl-metal dir="tests/spirv-cross" stage="fragment" ext="frag":
    @bash tools/msl_validity_sweep.sh {{dir}} {{stage}} {{ext}}

# large-corpus GLSL backend-validity sweep — the GLSL analog of msl-metal /
# wgsl-naga. Cross-compiles every shader to GLSL and compile-checks the output with
# glslangValidator (the real GLSL oracle), trying Vulkan (-V) then desktop mode. A
# shader is VALID if EITHER mode compiles; INVALID (both reject) = a backend bug (the
# plausible-but-wrong class); honest-error = the zioshade frontend refused. Exits
# non-zero on any INVALID. Requires glslangValidator on PATH; run on demand.
#   just glsl-glslang                                  # tests/spirv-cross fragments
#   just glsl-glslang tests/glslang-430 fragment frag
glsl-glslang dir="tests/spirv-cross" stage="fragment" ext="frag":
    @bash tools/glsl_glslang_sweep.sh {{dir}} {{stage}} {{ext}}

# All three stages of the GLSL gate. Same fragment-only blind spot as HLSL (the gates
# default to fragment); this runs vertex+compute too. Found 29 unchecked GLSL vertex+
# compute compile-INVALID (2026-07-25).
glsl-glslang-all:
    @bash tools/glsl_glslang_sweep.sh tests/spirv-cross fragment frag
    @bash tools/glsl_glslang_sweep.sh tests/spirv-cross vertex vert
    @bash tools/glsl_glslang_sweep.sh tests/spirv-cross compute comp

# All three stages of the MSL gate. Found 39 unchecked MSL vertex+compute compile-INVALID.
msl-metal-all:
    @bash tools/msl_validity_sweep.sh tests/spirv-cross fragment frag
    @bash tools/msl_validity_sweep.sh tests/spirv-cross vertex vert
    @bash tools/msl_validity_sweep.sh tests/spirv-cross compute comp

# run tests with verbose output
test-verbose:
    {{zig}} build test --summary all 2>&1 | grep -E "passed|failed|leaked|error:"

# ── DXC validation ───────────────────────────────────────────────────

# validate saved HLSL outputs with DXC (requires dxc.exe on PATH)
# -Fo must be a real, writable path on Windows (/dev/null is not a valid dxc
# output target), so compile to throwaway .dxil files and delete them after.
validate-dxc: generate-outputs
    dxc -T ps_6_0 -E main tests/wintty/crt_output.hlsl -Fo tests/wintty/crt_check.dxil
    # NOTE: crt_output.hlsl is regenerated by generate-outputs; focus_output.hlsl is a
    # committed snapshot (its generator, dump_shader.zig, still needs the 0.15.2 migration).
    # TODO: regenerate focus_output.* in-gate once the sibling tools are migrated.
    dxc -T ps_6_0 -E main tests/wintty/focus_output.hlsl -Fo tests/wintty/focus_check.dxil
    rm -f tests/wintty/crt_check.dxil tests/wintty/focus_check.dxil
    @echo "DXC validation: ALL PASSED"

# validate saved MSL outputs with the real Metal compiler (macOS runtime makeLibrary) —
# the MSL analog of validate-dxc. Catches the silent-wrong class: emit valid-looking
# MSL at exit 0 that the Metal compiler rejects. Builds tools/MslCompileCheck.swift on
# demand (cached in .zig-cache/mslcheck). macOS only (needs swiftc).
validate-metal:
    @command -v swiftc >/dev/null 2>&1 || { echo "validate-metal requires swiftc (macOS)"; exit 2; }
    @mkdir -p .zig-cache
    @test -x .zig-cache/mslcheck -a ! tools/MslCompileCheck.swift -nt .zig-cache/mslcheck || swiftc -O tools/MslCompileCheck.swift -o .zig-cache/mslcheck
    .zig-cache/mslcheck tests/wintty/crt_output.msl
    .zig-cache/mslcheck tests/wintty/focus_output.msl
    @echo "Metal validation: ALL PASSED"

# regenerate saved HLSL outputs from wintty shaders
generate-outputs:
    {{zig}} run -ODebug --dep zioshade -Mroot=tools/dump_crt_hlsl.zig -Mzioshade=src/root.zig

# regenerate docs/STATUS.md (single source of truth) from a real conformance run
status:
    @bash tools/gen_status.sh

# regenerate docs/COVERAGE_MATRIX.md -- per-backend SPIR-V opcode/capability coverage,
# computed statically from the code + the empirical reach of the real SPIR-V fixtures.
# Bounds the correctness scope (which Op opcodes each backend handles vs the modelled
# universe) so it is measurable, not corpus-implicit. See tools/coverage_matrix.sh.
coverage-matrix:
    @bash tools/coverage_matrix.sh > docs/COVERAGE_MATRIX.md
    @echo "docs/COVERAGE_MATRIX.md regenerated (run 'bash tools/coverage_matrix.sh' to preview)"

# integer-corpus UB-free contract guard (r2d.4): machine-check that no corpus shader
# contains OpUndef or an integer div/mod by constant 0 / INT_MIN-by-minus-1. Variable
# divisors that are runtime-guarded (e.g. gcd's Euclid loop) are INFO, not failures.
# This is what makes `just prove-integer` an airtight "any DIFFER is a real bug" claim.
# See tests/integer_corpus/README.md for the full contract (incl. what is NOT UB:
# integer add/mul/sub wrap is defined in SPIR-V).
ub-check:
    @bash tools/integer_corpus_ub_check.sh

# Metamorphic equivalence oracle (r2d.5): for each pair of PROVABLY-equivalent GLSL
# programs in tests/integer_corpus/metamorphic/, cross-compile both with zioshade's MSL
# backend and render-diff on Metal. The two must render identically (the rewrite preserves
# integer semantics). A DIFFER is a guaranteed zioshade miscompilation -- the operand-level
# class differential-testing ACROSS compilers cannot reach. Pass 1 is curated pairs;
# spirv-fuzz-style auto-generation is pass 2. macOS/Metal only.
metamorphic:
    @bash tools/metamorphic_check.sh

# Minimize a failing SPIR-V (one zioshade cross-compiles wrongly) to a minimal repro via
# spirv-reduce (r2d.6). Ad-hoc debugging tool -- when the fuzzer or a prove/render hit
# surfaces a failing shader, this shrinks a large module to a small one for the bug report.
# Usage: just reduce <input.spv> <mode>   (modes: crash-msl|crash-glsl|crash-hlsl|crash-wgsl|reject-glsl|reject-wgsl)
# For the custom-interestingness escape hatch or spirv-reduce opts (--step-limit=N), run
# tools/reduce.sh directly: `bash tools/reduce.sh <input.spv> custom <script> --step-limit=N`
reduce input mode:
    @bash tools/reduce.sh {{input}} {{mode}}

# ── fuzzing ──────────────────────────────────────────────────────────

# run the structured-GLSL fuzzer (ReleaseFast). Default 100k iters; override:
#   just fuzz 1000000
fuzz count="100000":
    {{zig}} build fuzz -Doptimize=ReleaseFast -- --count {{count}}

# robustness milestone: ≥1M fuzz iterations must be 100% clean (0 fail).
# Verified clean at 1,000,000 iters (seed 1) — see CHANGELOG.
fuzz-million:
    {{zig}} build fuzz -Doptimize=ReleaseFast -- --count 1000000 --seed 1

# 5k-iteration smoke pass, exactly what the fuzz-smoke CI job runs
fuzz-smoke:
    {{zig}} build fuzz -- --count 5000

# e54.4: arbitrary-SPIR-V backend validity sweep. Validity-checks zioshade's emitted
# MSL/HLSL/GLSL/WGSL on ARBITRARY .spv input (external SPIR-V, not GLSL source), with
# spirv-cross discrimination. Now green (INVALID=0, PRs #506-519) and wired into both
# `ci` (local) and GitHub Actions (Linux: GLSL complete-oracle + WGSL via naga; macOS:
# MSL on a real Metal compiler; Windows: HLSL on the Vulkan SDK's DXC). Each leg skips
# gracefully where its compiler is absent. Exits non-zero on any regression.
spv-validity:
    {{zig}} build cli
    tools/spv_input_validity_sweep.sh tests/arbitrary_spirv

# r2d.2: CTS ingestion credibility sweep. Feeds the vendored GraphicsFuzz corpus
# (SPIRV-Tools' fuzz seeds, tests/cts/graphicsfuzz) straight through the binary-ingestion
# path and reports, per backend, ok / invalid-output / honest-error / CRASH. NON-GATING
# credibility report: invalid-output is expected breadth; the ONLY gate is a NEW crash
# (count exceeding tests/cts/baseline.txt). GLSL complete-oracle (glslang) + WGSL candidate
# (naga) + MSL (Metal) + HLSL (DXC); each backend skips gracefully where its compiler is
# absent, so the msl/hlsl baseline rows are enforced by the macOS and Windows CI jobs.
# Surfaces mandate-violation crashes on broad real SPIR-V.
cts-ingestion:
    {{zig}} build cli
    tools/cts_ingestion_sweep.sh tests/cts/graphicsfuzz

# ── benchmarks ───────────────────────────────────────────────────────

# run wintty shader benchmark (ReleaseFast, 50 iterations)
bench:
    {{zig}} build bench

# lib-vs-lib: zioshade vs SPIRV-Cross, both IN-PROCESS, same SPIR-V → GLSL/HLSL/MSL
# (honest comparison; needs the Vulkan SDK spirv-cross libs). Override iters:
#   just lib-bench 2000
lib-bench count="1000":
    {{zig}} build lib-bench -- --iters {{count}}

# ── lint / check ─────────────────────────────────────────────────────

# check compilation without building (fast syntax/type check)
check:
    {{zig}} build 2>&1 | head -1

# zig fmt --check over src (mirrors the fmt CI job)
fmt-check:
    {{zig}} fmt --check src

# reformat src in place
fmt:
    {{zig}} fmt src

# fail if the generated minWordCount table in src/spirv_cross_common.zig has
# drifted from the vendored Khronos grammar (tools/spirv.core.grammar.json).
# A hand edit inside the BEGIN/END GENERATED block is a silent-rejection hazard,
# so it is a gate, not a convention. Offline: no network needed.
check-min-word-count:
    python3 tools/gen_min_word_count.py --check src/spirv_cross_common.zig

# fail if build.zig.zon's .version and src/version.zig's version_string (what
# `zioshade --version` prints) have drifted apart. The zon is not importable,
# so the pair can only be kept honest by checking. Same gate-not-convention
# rule as check-min-word-count. Offline: no network needed.
check-version-sync:
    python3 tools/check_version_sync.py

# ── full CI pipeline ─────────────────────────────────────────────────

# run everything CI would run (incl. backend oracle differentials)

# ── full CI pipeline ─────────────────────────────────────────────────

# C ABI smoke, exactly what the c-abi CI job runs
c-abi:
    {{zig}} build c-lib --summary all
    {{zig}} build c-example --summary all
    {{zig}} build run-c-example

# One dependency per workflow step:
#   fmt-check, check-min-word-count, check-version-sync -> job `fmt`
#   build, cli, examples, test, test-hlsl  -> job `build-test`
#   test-conformance, strict-gate          -> job `conformance`
#   spv-validity                           -> job `spv-validity`
#   cts-ingestion                          -> job `cts-ingestion`
#   structural-drop, unreachable-scan-all  -> job `structural-drop` (one job: the scan
#                                             reuses the CLI the sweep already built)
#   fuzz-smoke                             -> job `fuzz-smoke`
#   c-abi                                  -> job `c-abi`
# (job `package-smoke` has no `just` twin: its whole point is assembling a copy of the
# tree from build.zig.zon's .paths, which only makes sense on a fresh checkout, not in
# a developer worktree.)
# Keep this list in step with the workflow: a gate that runs in only one of the two
# is a gate nobody is really watching. The difference is coverage, not job set: this
# runs one OS and one toolchain, CI runs the same jobs across 3 OSes and both 0.15.2
# and 0.16. Oracle- and hardware-dependent gates live in `ci-full`, not here, because
# the hosted runners cannot run them.
#
# the workflow's job set, run locally on this OS with Zig 0.15.2
ci: fmt-check check-min-word-count check-version-sync build cli examples test test-hlsl test-conformance strict-gate spv-validity cts-ingestion structural-drop unreachable-scan-all fuzz-smoke c-abi
    @echo ""
    @echo "═══════════════════════════════════════"
    @echo "  CI PASSED (this OS, Zig 0.15.2 only)"
    @echo "═══════════════════════════════════════"

# Adds the gates that cannot run on the hosted runners: DXC (HLSL), Metal (MSL
# render), and the spirv-cross / naga structural differentials.
#
# `ci` plus the gates that need local oracles or hardware
ci-full: ci validate-dxc validate-metal oracle-diff
    @echo ""
    @echo "═══════════════════════════════════════"
    @echo "  CI-FULL PASSED (incl. local oracles)"
    @echo "═══════════════════════════════════════"

# ── cleaning ─────────────────────────────────────────────────────────

clean:
    rm -rf zig-out .zig-cache

# ── utilities ────────────────────────────────────────────────────────

# verify zig version is 0.15.2
check-zig:
    @mise exec -- zig version | grep -q "0.15.2" && echo "Zig 0.15.2 ✓" || (echo "ERROR: expected Zig 0.15.2" && exit 1)

# show test counts summary
summary:
    @echo "Unit tests:" && {{zig}} build test --summary all 2>&1 | grep "passed\|failed\|leaked" | head -1
    @echo "HLSL tests:" && {{zig}} build test-hlsl --summary all 2>&1 | grep "passed" | head -1
