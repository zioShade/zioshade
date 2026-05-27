# Real-world corpus snapshot

`tests/external/` holds a small hand-authored corpus of canonical Vulkan /
WebGPU shaders. The `test-realworld` build step runs each shader through the
full glslpp pipeline (`compileToSPIRV` → SPIR-V → {GLSL, HLSL, MSL, WGSL})
and, when `naga` is on `PATH`, pipes the emitted WGSL through
`naga --input-kind wgsl` as an external sanity check.

Run with:

```bash
mise exec -- zig build test-realworld
```

The runner is opt-in; it is **not** part of the default `zig build test`
step, so the unit-test count (1724/1724 as of `c77f5452`) is unchanged.

## Snapshot — M8.5 seeding (commit `c77f5452`)

13-shader curated corpus, validated with `naga 29.0.3`:

| Backend  | PASS | FAIL | Notes                                                                                   |
|----------|-----:|-----:|-----------------------------------------------------------------------------------------|
| SPIR-V   |   13 |    0 | All shaders compile to valid SPIR-V via `compileToSPIRV`.                               |
| GLSL     |   13 |    0 | `spirvToGLSL` emits without error for every shader.                                     |
| HLSL     |   13 |    0 | `spirvToHLSL` returns output for every shader (see "known caveats" below).              |
| MSL      |   13 |    0 | `spirvToMSL` emits without error for every shader.                                      |
| WGSL     |   13 |    0 | `spirvToWGSL` emits without error for every shader.                                     |
| naga     |   11 |    2 | Two naga validation failures — see "Naga WGSL failures" below.                          |

### Naga WGSL failures

Two shaders produce WGSL that glslpp's WGSL backend emits successfully but
that `naga` rejects on parse:

1. **`10_atomic_add.comp`** — `naga` rejects:
   ```text
   atomic operation is done on a pointer to a non-atomic
   let v7: u32 = atomicAdd(&b.counter, 1u);
                            ^^^^^^^^^^ atomic pointer is invalid
   ```
   The WGSL backend should be marking the SSBO field as `atomic<u32>` when
   it sees `OpAtomicIAdd`. This is a real WGSL backend gap surfaced by the
   corpus.

2. **`12_buffer_reference.frag`** — `naga` rejects:
   ```text
   name `ref` is a reserved keyword
   4 │     ref: FloatRef,
            ^^^ definition of `ref`
   ```
   The WGSL backend doesn't escape GLSL identifiers that collide with WGSL
   reserved keywords (`ref`, `let`, `private`, ...). This is also a real
   WGSL backend gap surfaced by the corpus.

Both are tracked here as follow-up work; the corpus exists precisely to
make these regressions visible.

### Known caveats (no failure was raised)

Two shaders were predicted to fail in this snapshot but currently emit
output (potentially semantically incorrect):

- `06_minimal.vert` — HLSL vertex signature is the M5.0 known limitation.
  `spirvToHLSL` returns a string today; DXC validation of the output is not
  yet wired into `test-realworld`. Once M5.0 lands, this row should still
  pass and the DXC pass should pass too.
- `08_ssbo_write.comp` — HLSL compute SSBO emit is known-buggy as of
  `c77f5452`. Same situation — `spirvToHLSL` returns a string; semantic
  validation isn't run here.

Adding DXC validation to `test-realworld` is a natural next step for M5.3
follow-up work.

## Updating this snapshot

After landing changes that affect the corpus output, re-run the runner and
update the table above with the new commit SHA and pass counts. Honest
numbers beat optimistic ones — the corpus is most useful when it tracks
reality.
