# GLSL front-end acceptance parity: zioshade vs glslang

Measured 2026-08-21 at `5c2d1460` (includes PR #663, which the first run of
this measurement forced: ghostty's real shader set crashed the front-end on
every include-bearing unit before it).

## Why this measurement

The binding constraint on zioshade is adoption, not correctness (the
cross-compiler correctness ledger is closed: 0 invalid outputs on all
corpora, all backends). The pitch to a consumer that today builds a C++
shader stack — ghostty, but also any shadertoy-shaped pipeline — stands or
falls on one question: **does the GLSL front-end accept the GLSL that real
applications actually contain, at glslang parity?** This document answers it
with a two-oracle differential run, the same methodology the backends are
held to.

## Method

- Corpora: every in-tree GLSL source — `tests/spirv-cross` (1674),
  `tests/render_compare` (83), `tests/glslang-430` (42, glslang's own
  torture suite: intentionally-invalid files included), `tests/ghostty` (9,
  ghostty's real shader set; the `common.glsl` header is driven through the
  units that include it), `tests/shadertoy_style` (2), `tests/wintty` (5;
  2 are prefix-expecting fragments that are incomplete sources by design).
  1813 sources total.
- Oracle A (glslang): `glslangValidator -V -S <stage> -I<dir>`, Vulkan
  SPIR-V semantics, the mode a SPIR-V-producing consumer uses. `#include`
  directives are textually expanded first (shaderc semantics; bare
  `#include` needs `GL_GOOGLE_include_directive` under glslangValidator).
- Oracle B (zioshade): `zioshade spirv` (the front-end alone, GLSL to
  SPIR-V, no backend) on the ORIGINAL file — native `#include` handling is
  part of what is being measured.
- 20 s timeout per tool per file; accept = exit 0.

## Matrix

| corpus | both accept | glslang only | zioshade only | both reject |
|---|---:|---:|---:|---:|
| tests/spirv-cross | 808 | 15 | 756 | 95 |
| tests/render_compare | 83 | 0 | 0 | 0 |
| tests/glslang-430 | 3 | 1 | 16 | 21 |
| tests/ghostty | 2 | 0 | 7 | 0 |
| tests/shadertoy_style | 0 | 0 | 2 | 0 |
| tests/wintty | 2 | 0 | 0 | 2 |
| **ALL** | **898** | **16** | **781** | **118** |

**Acceptance parity: 898/914 = 98.2%** of everything glslang accepts,
zioshade also accepts.

## The gap: 16 files, all vendor/compute extensions

| class | n | shape |
|---|---:|---|
| UndeclaredIdentifier | 8 | `buffer_reference`/coop-vec/gcn-asm — VK_NV/GL vendor extension builtins |
| InvalidAssignment | 2 | `buffer_reference` bitcast family |
| semantic (fp64/int64) | 2 | desktop 64-bit arithmetic ops |
| SemanticFailed | 2 | 8-bit arithmetic, cooperative-matrix tensor |
| TypeMismatch | 1 | `nonuniformEXT` qualifier |
| codegen | 1 | ES 310 nested member layout (`row_major` member inside std140 UBO) |

None of these occur in ghostty's set, the shadertoy-style corpus, or any
fragment/vertex desktop shader in the tree. They are Vulkan compute
vendor-extension features, recorded here as named acceptance debt rather
than open work.

## The zioshade-only cell: superset, not laxness

781 files are accepted by zioshade and refused by `glslangValidator -V`.
Re-running glslang in GL mode (no `-V`) reclassifies them:

- **557** accepted in GL mode — valid desktop GLSL that only fails Vulkan
  strictness (no explicit `location`/`binding`, legacy varyings). zioshade
  assigns these itself when emitting SPIR-V.
- **224** rejected by both glslang modes, of which **198** are
  `gl_FragColor` in a core `#version` — the shadertoy dialect: removed from
  core GLSL, universally consumed in practice. The remaining 26 are glslang
  strictness long tail (unrequested geometry/tessellation extensions,
  reserved words, constructor arity).

Laxness check: a 60-file uniform random sample of this cell's zioshade
outputs was run through `spirv-val` — **60/60 clean**. Accepting more is a
deliberate dialect decision with valid SPIR-V behind it, the same position
spirv-cross's reference outputs embody (they are the source of most of this
cell).

## ghostty's real set

9/9 units compile to `spirv-val`-clean SPIR-V. glslang `-V` accepts 2 of
the 9 (it refuses `gl_VertexID` under Vulkan semantics and location-less
varyings). The first run of this measurement crashed the front-end on all
7 include-bearing units — the `#include` token-text address-space bug fixed
in PR #663; the existing include suite was containment-shaped (traversal,
symlinks, cycles) and had never exercised content-bearing includes.

## Residue

- The 16-file gap above, named by class.
- CLI diagnostics: front-end failures surfaced through `zioshade spirv`
  print `codegen_failed (no specific location; compile with the library
  diagnostics API for details)` where the library API carries a real
  message; the CLI should forward it.

Rerun: the harness lives outside the tree (two-oracle driver over
`tests/*`), method documented above is the contract.
