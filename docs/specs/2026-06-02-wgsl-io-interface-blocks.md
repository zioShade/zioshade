# Spec: WGSL stage I/O interface blocks (the largest remaining naga-reject cluster)

**Status:** proposed (2026-06-02)
**Severity:** silent-wrong (naga-reject), WGSL backend
**Yield:** ~10 corpus shaders — the single biggest remaining WGSL↔naga cluster.
**Witnesses:** `in-block-qualifiers.frag`, `io-block.legacy.vert`, `io-blocks.legacy.frag`,
`layout-component.desktop.frag`, `multiple-struct-flattening.legacy.frag`,
`link.multi{Anon,}Blocks{Valid,Invalid}*.vert` (×5).

## Problem

A GLSL stage I/O **interface block**:
```glsl
layout(location = 0) in VertexData {
    flat float f; centroid vec4 g; flat int h; float i;
} vin;
layout(location = 4) in flat float f;   // separate top-level varyings too
void main(){ FragColor = vin.f + vin.g + float(vin.h) + vin.i + f + ...; }
```
lowers to a SPIR-V `Input` `OpVariable` whose type is an `OpTypeStruct`
(`VertexData`), with a block-level `OpDecorate %vin Location 0`. glslpp emits:
```wgsl
fn main(@location(0) vin: VertexData, @location(4) @interpolate(flat) f: f32, …)
```
which is doubly wrong: (1) **`VertexData` is never declared** (naga: "no
definition in scope for identifier: `VertexData`"), and (2) a struct entry
parameter must NOT carry `@location` — its *members* do.

## Oracle / reference behaviour

WGSL expresses a stage-I/O block as a **struct whose members carry `@location`
and `@interpolate`**, passed/returned by value:
```wgsl
struct VertexData {
    @location(0) @interpolate(flat) f: f32,
    @location(1) g: vec4f,
    @location(2) @interpolate(flat) h: i32,
    @location(3) i: f32,
}
@fragment
fn main(vin: VertexData, @location(4) @interpolate(flat) f: f32, …) -> @location(0) vec4f {
    return vin.f + vin.g + f32(vin.h) + vin.i + f + …;   // member access unchanged
}
```
The body's `vin.f` already works because `vin` is a by-value struct parameter.

## Design (glslpp, `spirv_to_wgsl.zig`)

Gate on the precise shape so non-block inputs are byte-identical (the input
emission path feeds ~1900 passing shaders — zero-regression is mandatory):

1. **Detect:** an `Input`/`Output` `OpVariable` whose pointee type is an
   `OpTypeStruct` decorated `Block` (interface block) — distinct from the
   synthesized vertex `VertexOutput`. Skip everything below when absent.
2. **Declare the block struct** once, before `fn main`:
   - member name from `OpMemberName`; type from `wgslType(member_type)`.
   - **`@location`** per member: base = the variable's `Location` decoration;
     each member consumes `locationSpan(type)` slots (1 for scalars/vectors ≤4
     comps and 16-bit/32-bit; a `matCxR` consumes C; f64/dvecN consume 2 each).
     v1 may assume 1/slot and `log()` a TODO for matrix/double members (none in
     the witnesses) rather than silently mis-assign.
   - **`@interpolate`** per member from member decorations: `Flat` →
     `@interpolate(flat)`; `Centroid`/`Sample` sampling → `@interpolate(perspective,
     centroid|sample)`; integer members are implicitly flat (already handled by
     `isIntegerWgslType`). Reuse the existing per-varying interpolation logic.
3. **Emit the entry parameter** as `vin: VertexData` with **no** `@location`
   (the param is the block instance). For an **output** block, add it to the
   `FragmentOutput`/`VertexOutput` return struct as a nested field — or, simpler
   for v1, flatten an output block to individual return-struct fields.
4. **Body:** unchanged — `OpAccessChain %vin %memberIdx` already emits `vin.<m>`.

## Risks / verification
- **Zero-regression gate:** the detection must fire ONLY on Block-decorated
  struct I/O. Verify the per-shader reject-set diff (`comm`) shows only the ~10
  block shaders flip and **nothing** regresses; `test-wgsl` / `test-realworld` /
  `conformance` (PASS 2074+, FAIL 0) hold.
- **Location overlap:** confirm block-member locations don't collide with the
  separate top-level varyings (in `in-block-qualifiers` the block is 0–3 and the
  loose varyings are 4–7 — already disjoint by construction in valid GLSL).
- **Output blocks** (`io-block.legacy.vert`) are the trickier half; land input
  blocks first (most of the cluster), output blocks second.

## TDD
1. RED: `in Block { flat float f; vec4 g; } vin; … vin.f + vin.g` → assert the
   WGSL declares `struct Block {` with `@location(0) @interpolate(flat) f` and
   `@location(1) g`, the param is `vin: Block` (no `@location`), and naga validates.
2. GREEN: steps 1–4 (input blocks).
3. Repeat for an output block.
