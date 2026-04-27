# Autoresearch Ideas

## CURRENT STATUS: 189 passes, 1 compile error (GPA leak), 7 spirv-val failures

### Remaining 7 spirv-val failures:
1. **spv.newTexture.frag** — Sampled Image type mismatch (integer samplers use float sampled type)
2. **atomic.comp** — Undefined ID %110 (phantom ID from imageAtomic ops)
3. **fp-atomic.nocompat.vk.comp** — AtomicIAdd on float (needs OpAtomicFAddEXT)
4. **gather-dref.frag** — Vector out of bounds (textureGather on shadow sampler needs OpImageDrefGather)
5. **generate_height.comp** — PackHalf2x16 returns vec2 not uint (simple result type fix)
6. **ground.frag** — No OpEntryPoint (preprocessor #if needs multi-level macro expansion)
7. **texture-proj-shadow.desktop.frag** — Coordinate too small for textureProj

### 1 compile error (intermittent GPA leak):
- `partial-write-preserve.frag` — exits 0 with PASS but GPA leak sometimes causes classification as compile error
- Root cause: overload map's `dupe` allocations for param types leak when module is freed

## COMPLETED THIS SESSION
- Shadow sampler types + Dref instructions (texture-shadow-lod, newTexture fixed)
- Function overloading support (type-alias.comp, partial-write-preserve.frag fixed)
- Fixed autoresearch.sh build script (direct zig build-exe)

## HIGH PRIORITY — Fix generate_height.comp (simple)
PackHalf2x16 result type should be uint not vec2. Add case to result_ty inference.
BUT: adding the fix causes 2 compile errors (up from 1) due to GPA leak interaction. 
The fix itself is correct but the leak amplification needs investigation.

## MEDIUM PRIORITY
- Integer sampler types (isampler2d/usampler2d) for spv.newTexture.frag
- OpImageDrefGather for gather-dref.frag
- ground.frag preprocessor multi-level macros

## LOW PRIORITY
- atomic.comp phantom IDs
- fp-atomic float atomics
- texture-proj-shadow coord size
