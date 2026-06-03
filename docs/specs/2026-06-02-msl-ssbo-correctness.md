# Spec: MSL SSBO emission correctness (silent-wrong cluster)

**Status:** proposed (2026-06-02)
**Backlog:** #6 (MSL builtin I/O completion) + #2 (zero unexplained spirv-cross
divergences). **Priority: HIGH — this is silent-wrong** (invalid MSL emitted with
exit 0), the #1 thing the project forbids.

## Discovery

Comparing glslpp MSL against the spirv-cross `--msl` oracle on a trivial compute
SSBO shader surfaced **three** distinct silent-wrong bugs. Repro:

```glsl
#version 450
layout(local_size_x=1) in;
layout(std430, binding=0) buffer Buf { uint cnt; float vals[]; } data;
void main(){ data.cnt = 5u; data.vals[0] = 1.0; }
```

**glslpp (invalid MSL):**
```cpp
struct data { uint cnt; float vals; };          // BUG 3: named after instance; BUG 2: runtime array -> scalar
kernel void main0(device data* data [[buffer(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]]) {
    data.cnt = 5u;                              // BUG 1: '.' on a pointer (device data*) — must be -> ; also name collides with type
    data.vals[0] = 1.0;                         // BUG 2: indexing a scalar
}
```

**spirv-cross (reference, valid):**
```cpp
struct Buf { uint cnt; float vals[1]; };
kernel void main0(device Buf& data [[buffer(0)]]) {
    data.cnt = 5u;
    data.vals[0] = 1.0;
}
```

### Bug 1 — pointer parameter accessed with `.`  (most severe; pervasive)
SSBO params are emitted `device T* name` (`spirv_to_msl.zig:2023` non-argbuf;
`:2066` argbuf local) but the body emits member access with `.` (`name.member`).
`.` on a pointer is a hard C++/MSL compile error. **Every SSBO MSL shader is
invalid.** The textual `assertContains` tests (e.g. msl_tests.zig:510/527 only
check `simd_all`/`simd_any`) never caught it, and there is no Metal compiler on
Windows to fail it.

### Bug 2 — runtime array `T[]` emitted as scalar `T`
`emitStructMembers` lowers a `TypeRuntimeArray` member (`float vals[]`) to
`float vals;` (scalar), then the body indexes `vals[0]` — invalid. spirv-cross
emits `float vals[1];` (a 1-element array stand-in for the flexible member).

### Bug 3 — struct named after the instance, colliding with the param
`spirv_to_msl.zig:902` emits `struct {sb.name}` using the **instance** name
(`data`), not the **block** name (`Buf`). Combined with the param also named
`data`, the result is `device data* data` — type and variable share an
identifier. spirv-cross names the struct after the block (`Buf`).

## Fix design (match spirv-cross)

1. **Param as reference:** emit `device {Block}& {name}` (not `{T}* {name}`) at
   the non-argbuf site (:2023). `.` access then becomes correct. **Verify** no
   body path relies on pointer semantics (`name->m`, `name[i]` for
   array-of-block SSBOs); if array-of-block exists, that case keeps a pointer and
   the body must use `[i].m` — enumerate before flipping.
   - **Argbuf path (:2066):** the set member is `device Block*`; bind the local
     as a reference `device {Block}& {name} = *set{d}.{name};` so the shared body
     emitter's `.` access is correct in both modes.
2. **Struct name = block name:** name the emitted struct after the block
   (OpName of the struct type) — `Buf` — falling back to a synthesized unique
   name, never the instance name. Update the body's type references accordingly.
3. **Runtime array member:** emit the flexible-array member as `T name[1]`
   (spirv-cross convention) so `name[i]` indexing is valid.

## Oracle / verification (deterministic — sweep is noisy on Windows)
- Primary oracle: **spirv-cross `--msl`** attribute + structure parity on the 14
  SSBO `.comp` corpus fixtures (`tests/spirv-cross/*.comp` with a buffer block).
- Deterministic regression method (proven this session): byte-diff ALL corpus
  MSL outputs baseline-vs-fix; the changed set must be exactly the SSBO shaders;
  spot-check each changed output parses as valid MSL structure vs spirv-cross.
- `just test`/`test-conformance` PASS 2074 / FAIL 0 must hold.
- Add real correctness tests: assert `device {Block}&` (not `* {name}` with `.`),
  runtime array `[1]`, struct named after block — not just `[[buffer(`.

## Also-found (separate, lower severity) — spurious unused builtins
glslpp emits unused builtin params spirv-cross omits:
- compute: always emits `gl_GlobalInvocationID [[thread_position_in_grid]]` even
  when only `threadgroups_per_grid` / `thread_position_in_threadgroup` is used.
- fragment: always emits `gl_FragCoord [[position]]` even when unused.
Not invalid MSL (Metal allows unused builtin inputs) so NOT silent-wrong — a
faithfulness gap. Gate builtin-param emission on actual use. Track separately.

## TDD plan
1. RED: SSBO compute shader → assert MSL has `device Buf&` + `vals[1]` + struct
   `Buf` (currently fails on all three).
2. GREEN: implement 1–3.
3. Oracle-gate: spirv-cross `--msl` structural parity on the 14 SSBO fixtures;
   byte-diff shows only SSBO shaders changed; conformance unchanged.
