# WebGPU CTS WGSL corpus (vendored slice)

Vendored WGSL corpus for `tools/webgpu_cts_sweep.sh` (`just webgpu-cts`), the
webgpu:shader ingestion credibility harness (r2d.1).

- **Source:** per-case WGSL shader text extracted from the `webgpu:shader,validation`
  suite of [gpuweb/cts](https://github.com/gpuweb/cts), the WebGPU conformance
  test suite. The CTS has no standalone WGSL corpus; every case's shader is
  assembled inside its TypeScript framework and handed to the implementation
  under test via `t.expectCompileResult(expected, code)`.
- **Pinned commit:** `2959e1c` ("Subgroup_size_control enables subgroups (#4693)").
- **License:** BSD-3-Clause (WebGPU CTS Contributors). Vendored into zioshade
  under that license; the copyright notice lives in the CTS repository.
- **Extraction:** `tools/webgpu_cts_fetch.sh` clones the CTS at the pinned
  commit, emits its TS tree to JS with `tsc`, then `tools/webgpu_cts_dump.mjs`
  drives the framework's own case enumeration (`g.iterate()`) headlessly: the
  GPU device is faked, `expectCompileResult` is patched to record the shader
  text instead of compiling it. `tools/webgpu_cts_extract.py` then carves this
  slice. The dumped shaders are EXACTLY what the CTS would have submitted to a
  real WebGPU implementation.
- **Contents:** `cases/*.wgsl` (1613 unique shaders, ~320 KB of WGSL) +
  `manifest.tsv` (per case: id, entry point, stage, originating spec file,
  test name, params). Slice rule: unique-by-text shaders with
  `expected=true` and at least one entry point, capped at 100 per originating
  spec file, picked in sha1 order (deterministic; a refresh changes only what
  the CTS changed). 91 distinct spec files are represented; the full
  extraction pool at this pin is 2,047 per-file-bucketed uniques (2,046
  distinct texts; one shader is witnessed by two spec files and deduped at
  emission), so the slice covers 79% of the pool while keeping the vendored
  bytes bounded.

## What the harness measures, and what it does NOT

The sweep runs each case through the only round trip available to a SPIR-V ->
WGSL cross-compiler: `CTS WGSL --naga--> SPIR-V --zioshade--> WGSL --naga-->`.
Read `tools/webgpu_cts_sweep.sh`'s header for the direction rationale.

The numbers mean: of this CTS-derived corpus, how much zioshade ingests and
lowers to WGSL that naga accepts (`roundtrip-valid`), how much it refuses
loudly (`zioshade-refused`), and how much it emits broken output for at exit 0
(`zioshade-invalid`, the silent-wrong class).

The numbers do NOT mean, and must never be cited as:

- **A WebGPU CTS pass.** The CTS executes shader runtime semantics on a real
  GPU; nothing here executes anything. This is ingestion/lowering validity of
  a corpus derived from the CTS, through a WGSL -> SPIR-V -> WGSL round trip
  the CTS itself never performs.
- **A conformance fraction of webgpu:shader.** The corpus is a bounded,
  validation-suite-only slice: the execution suite (GPU behavior) is out of
  scope, subcase-iterating tests are skipped by the dumper, and the slice caps
  per-file representation.
- **Coverage of zioshade's other backends.** This leg exercises the WGSL
  backend only (see `tools/cts_ingestion_sweep.sh` for the broad corpus legs).

`upstream-convert-failed` cases are WGSL the CTS expects to compile but NO
local upstream converter can turn into SPIR-V: the sweep tries naga first and
tint (env `TINT`, else `tint` on PATH; dawn 5e9e5136 works) second. With both
present the class shrinks to pipeline-overridable constants without values,
which neither converter can materialize headlessly. Without tint the class is
the full set of naga's front-end gaps (at this pin: the `subgroups` enables,
`@diagnostic`, const-expr `determinant`, `atomic_vec2u_min_max`, ...). They
are the upstream ceiling, not zioshade failures, and are reported separately
for exactly that reason.

## Refresh

```bash
tools/webgpu_cts_fetch.sh            # regenerate cases/ + manifest.tsv (PER_FILE=N overrides the cap)
PER_CASE=tests/webgpu_cts/per_case.tsv tools/webgpu_cts_sweep.sh
# then update baseline.txt counts + the pinned commit above
```
