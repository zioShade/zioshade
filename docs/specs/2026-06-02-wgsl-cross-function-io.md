# Spec: WGSL cross-function I/O globals (`var<private>` promotion)

**Status:** proposed (2026-06-02)
**Backlog:** #2/#3 (WGSL↔naga divergences). Closes the largest remaining
`undef-identifier` sub-bucket.

## Problem

In GLSL, `in`/`out`/uniform globals are visible in *every* function. In SPIR-V
they are module-scope `OpVariable`s loaded/stored anywhere. In WGSL, **`@location`
and `@builtin` I/O are entry-point parameters / return values — they cannot be
module-scope**, so a *helper* function that references a stage input emits an
undefined identifier:

```glsl
layout(location=0) in vec2 uv;
float effect(vec2 p) { return pattern(p + uv, 2.0); }   // uv used in a helper
void main() { fragColor = vec4(effect(vec2(0.5))); }
```
```wgsl
fn effect(v18: vec2f) -> f32 {
    let v20: vec2f = v18 + uv;   // naga: "no definition in scope for identifier: uv"
    ...
}
@fragment fn main(@location(0) uv: vec2f) -> @location(0) vec4f { ... }
```

naga rejects — silent-wrong. Witnesses: `triple-nested-functions.frag`,
`modf.legacy.frag`, `modf-pointer-function-analysis.frag`, and others in the
`undef-identifier` bucket.

## Oracle / reference behaviour

`spirv-cross` (and naga's own GLSL-in path) handle this by **promoting the I/O
variable to a module-scope `var<private>`** and copying between it and the
entry-point parameter/return in a thin wrapper:

```wgsl
var<private> uv_1: vec2f;          // private module global
fn effect(p: vec2f) -> f32 { return pattern(p + uv_1, 2.0); }
fn main_inner() -> vec4f { ... }   // references uv_1, writes fragColor_1
@fragment fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
    uv_1 = uv;                     // copy param -> private global
    return main_inner();           // (or inline main_inner's body)
}
```

## Design (glslpp)

Gate precisely so **shaders that don't hit the pattern are byte-identical**
(zero regression risk for the ~1900 currently-passing fixtures):

1. **Detect** (new pre-pass): for each `Input`/`Output` global, scan whether any
   `OpLoad`/`OpStore`/`OpAccessChain` referencing it occurs inside a function
   that is **not** the entry function. Call this set `promoted`.
   - If `promoted` is empty → behave exactly as today (no change).

2. **Emit `var<private>`** for each promoted global at module scope, with a
   distinct name (e.g. `<name>_p`). Map the SPIR-V id → that name in `names`, so
   *all* references (in main and helpers) resolve to the private global
   uniformly.

3. **Entry wrapper bridging:**
   - Promoted **input**: keep the `@location(i)`/`@builtin` parameter on `main`
     (named `<name>`), and emit `<name>_p = <name>;` as the first statement of
     the entry body (before the rest of the body runs).
   - Promoted **output**: the body writes `<name>_p`; at the return site emit
     `return <name>_p;` (single-output) or include `<name>_p` in the
     `FragmentOutput(...)` / vertex-struct construction. Reuses the existing
     direct-return / MRT / depth machinery — feed it `<name>_p` instead of the
     output var id's name.

4. **Helper functions** need no special handling: once `names[input_id]` is the
   private-global name, the existing function-body emitter prints `uv_p`
   correctly, and the module-scope declaration makes it in-scope.

## Risks / verification

- **Regression gate:** the detection pre-pass must be exact. Verify with the
  per-shader set diff (`just wgsl-naga` → `comm -13/-23`, NOT the raw count —
  see the sweep retry note) that *only* the targeted fixtures flip PASS and
  **zero** regress. Plus deterministic `test-wgsl` / `test-realworld` /
  `conformance` (PASS 2074, FAIL 0) must hold.
- **Initialization order:** `var<private>` is zero-initialised; the `uv_p = uv`
  copy MUST precede any read. Emit it as the literal first statement of the
  entry body.
- **Name collisions:** the `_p` suffix must go through the existing
  keyword/identifier-uniquing path.
- **Builtins:** promoted builtins (e.g. `gl_FragCoord` used in a helper) follow
  the same path but the entry param keeps its `@builtin(...)` attribute.

## Out of scope (separate buckets, tracked in memory worklist)

- `for-loop-init.frag` 3rd bug: phi *init* value referencing the latch
  increment (`var v52 = v56` use-before-def) — a phi-init resolution bug, not
  cross-function I/O.
- 17 heterogeneous `entrypoint-invalid` (void-return mismatch, clip_distance
  builtin), type-mismatch, atomics, reserved-prefix.

## TDD plan

1. RED: a fragment shader with an input read in a helper function →
   `assertNoUndeclaredVTemp` + naga-valid (currently fails).
2. GREEN: implement steps 1–4.
3. Oracle-gate: naga PASS on `triple-nested-functions.frag`; per-shader diff
   shows no regressions; all deterministic gates green.
4. Repeat for an `out` global written in a helper.
