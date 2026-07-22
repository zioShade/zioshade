# AGENTS.md

Guidance for contributors and AI coding agents working in this repository. Read it
before making changes.

## What zioshade is

A pure-Zig compiler: GLSL to SPIR-V, and SPIR-V to HLSL / MSL / GLSL / WGSL, in one
module with no C++ runtime. It is extracted from and used by the `wintty` terminal.

## The one rule that matters

**Never emit plausible-but-wrong output.** When zioshade cannot faithfully translate
a construct, it must return a LOUD error (an honest error), not silently emit output
that renders incorrectly. A silent miscompile is the worst possible failure for this
project; an honest error is an acceptable one. Any change that trades an honest error
for a silent-wrong is a regression even if a test appears to pass.

## Toolchain

- **Zig 0.15.2 is the hard floor** (a comptime guard enforces it). The library, CLI,
  C ABI, and test suite build and pass on both 0.15.2 and 0.16. Newer versions are
  supported best-effort via capability detection, not version numbers.
- Version-specific shims live in `src/compat.zig` and `build_compat.zig`. Do not
  reach for `std.fs`, `std.process`, `std.Io`, Writergate APIs, or allocators
  directly across versions; route them through `compat`.
- On macOS, `export DEVELOPER_DIR=/Library/Developer/CommandLineTools` (the Xcode SDK
  can break 0.15.2 native linking).

## Build, test, prove

- `just ci` is exactly what GitHub CI runs (`test test-hlsl validate-dxc strict-gate
  oracle-diff`). Use it, not a bare `zig build test`.
- `just test` -- full suite. `just strict-gate` -- the conformance gate.
- `just prove` -- the differential proof (renders zioshade output vs an independent
  glslang to SPIRV-Cross reference on a real GPU and diffs, across fragment, vertex,
  and compute). Default is a 1/25 fragment sample; **`PROVE_FULL=1 just prove` runs
  the whole corpus and is the real correctness gate** -- a sampled run can go green
  while real miscompiles hide. Always PROVE_FULL before claiming correctness.
- Oracle tools the tests and proof need on PATH: `glslang` / `glslangValidator`,
  `spirv-cross`, `spirv-val` (spirv-tools), and `swiftc` + Metal (macOS) for the
  render differential. Without them, differential tests skip rather than fail.

## Adding a fix

1. Root-cause first (see the systematic-debugging discipline): dump the unoptimized
   SPIR-V, bisect optimizer passes, and round-trip both frontends through spirv-cross
   before proposing a fix. Symptom fixes are failure.
2. Add a regression test that fails before your fix and passes after. For a
   miscompile, prefer an oracle-free structural assertion (opcode/decoration check)
   in `tests/correctness_tests.zig` so it runs without external tools.
3. Run `PROVE_FULL=1 just prove` and `just ci` before you commit.

## House style

- **No em-dashes** anywhere (code, comments, docs). Use `--`.
- **No AI-attribution** in commits or files: no "Co-Authored-By", no "Generated with"
  footers.
- Match the surrounding code: `const` over `var`, exhaustive switches, `snake_case`.
- Keep changes minimal and focused; no drive-by refactors bundled with a fix.
- The CI `fmt` gate runs `zig fmt --check` on **0.15.2**. Do not commit 0.16-fmt
  reflow of files you did not logically change.

## Where things live

- `src/` -- frontend (`parser.zig`, `semantic.zig`), SPIR-V codegen (`codegen.zig`),
  optimizer (`compact_ids_passes.zig`), and backends (`spirv_to_hlsl.zig`,
  `spirv_to_msl.zig`, `spirv_to_glsl.zig`, `spirv_to_wgsl.zig`), plus `compat.zig`.
- `tests/` -- the suite and the `spirv-cross/` input corpus (SPIRV-Cross's own tests,
  used as a differential oracle).
- `tools/` -- the proof harness (`prove.sh`, `frag_oracle_check.sh`,
  `vert_numeric_check.sh`, `compute_diff.sh`, the Swift render/numeric checkers).
- `docs/IMPLEMENTATION_STATUS.md` -- honest scope and known limitations (including the
  deliberately-rejected constructs). `docs/STATUS.md` -- generated conformance counts,
  never hand-edited.
