# Autoresearch Ideas

## CURRENT STATUS: 189 passes, 1 compile error, 7 spirv-val failures

### Remaining 7 spirv-val failures:
1. **spv.newTexture.frag** — Sampled Image type mismatch (integer samplers use float sampled type)
2. **atomic.comp** — Undefined ID %110 (phantom ID from imageAtomic ops)
3. **fp-atomic.nocompat.vk.comp** — AtomicIAdd on float (needs OpAtomicFAddEXT)
4. **gather-dref.frag** — Vector out of bounds (textureGather on shadow sampler needs OpImageDrefGather)
5. **generate_height.comp** — PackHalf2x16 returns wrong type (was duplicate IDs, now fixed by overloading)
6. **ground.frag** — No OpEntryPoint (preprocessor #if needs multi-level macro expansion)
7. **texture-proj-shadow.desktop.frag** — Coordinate too small for textureProj (non-shadow textureProj issue)

### New compile error (1 file):
- Unknown which file. Likely GPA leak from overload map allocations causing non-zero exit. Need to investigate.

## HIGH PRIORITY — Integer sampler types
Add `isampler2d`/`usampler2d` types with int/uint sampled type in TypeImage.
Would fix spv.newTexture.frag. Similar to how we added sampler2d_ms and shadow types.

## MEDIUM PRIORITY

### Fix textureGather on shadow samplers (gather-dref.frag)
Need OpImageDrefGather instruction. Currently textureGather on shadow samplers dispatches to image_sample_dref which tries to extract Dref from vec2 coordinate — out of bounds.

### Fix generate_height.comp PackHalf2x16
The GLSL.std.450 PackHalf2x16 instruction returns uint, but our codegen might return float. Need to check the ext_inst dispatch.

### Fix ground.frag No OpEntryPoint
Preprocessor #if needs multi-level macro resolution.

### Fix atomic.comp phantom IDs
imageAtomicAdd etc. on image types need proper image variable handling (was attempted in previous session but reverted).

### Fix texture-proj-shadow.desktop.frag
Non-shadow textureProj(uSampler1D, vClip2) has vec2 coord which is too small. textureProj on 1D sampler needs vec2 (u, proj_divisor).

## LOW PRIORITY

### Fix fp-atomic (needs SPV_EXT_shader_atomic_float)
Requires extension support for float atomics.

### Fix the 1 compile error regression
Investigate which file causes the compile error. May be GPA leak from overload map allocations.
