# Autoresearch Ideas

## CURRENT STATUS: 185 passes, 0 compile errors, 12 spirv-val failures

### Remaining 12 spirv-val failures:
1. **newTexture.frag** — FAdd float+vec4 (swizzle `.y`/`.x` dropped after shadow texture calls)
2. **spv.newTexture.frag** — Sampled Image type mismatch (integer samplers use float sampled type)
3. **atomic.comp** — Undefined ID %110 (phantom ID from imageAtomic ops)
4. **fp-atomic.nocompat.vk.comp** — AtomicIAdd on float (needs OpAtomicFAddEXT)
5. **generate_height.comp** — Duplicate ID (function overloading)
6. **ground.frag** — No OpEntryPoint (preprocessor #if needs multi-level macro expansion)
7. **partial-write-preserve.frag** — Duplicate IDs (function overloading)
8. **texture-proj-shadow.desktop.frag** — OpStore vec4→float (shadow sampler returns vec4 not float + dropped `.x`)
9. **texture-shadow-lod-bias.frag** — FAdd float+vec4 (shadow sampler returns vec4 not float)
10. **texture-shadow-lod.frag** — FAdd float+vec4 (shadow sampler returns vec4 not float)
11. **torture-loop.comp** — Continue construct structural domination
12. **type-alias.comp** — Duplicate IDs (function overloading)

## HIGH PRIORITY — Requires shadow sampler types + Dref instructions
For shadow samplers (sampler2DShadow etc.), need:
1. Add `sampler2d_shadow` type to ast.zig (tried, reverted due to OpImageSampleImplicitLod needing vec4 result)
2. Use `OpImageSampleDrefImplicitLod` for shadow textures (returns scalar float + takes depth ref)
3. Similarly: `OpImageSampleDrefExplicitLod` for textureLod on shadow samplers
4. This would fix 3 files: texture-shadow-lod, texture-shadow-lod-bias, texture-proj-shadow

## HIGH PRIORITY — Requires integer sampler types
Add `isampler2d`/`usampler2d` types with int/uint sampled type in TypeImage.
Would fix spv.newTexture.frag. Similar to how we added sampler2d_ms.

## MEDIUM PRIORITY

### Swizzle on function call results (affects 4+ files)
The `.` after function calls is tokenized as double_literal. Needs lexer fix + semantic member_access.
Previous attempts always regress. Need arena-based error recovery.

### Function overloading (affects 3 files: partial-write-preserve, type-alias, generate_height)
Our compiler uses name-only lookup. Need signature-based function resolution.

### Fix torture-loop.comp continue construct
Structural domination issue in loop control flow.

### Fix ground.frag No OpEntryPoint
Preprocessor already has single-level macro resolution for #if. Needs multi-level resolution.

### Fix atomic.comp phantom IDs
imageAtomicAdd etc. on image types need proper image variable handling.

## LOW PRIORITY

### Fix fp-atomic (needs SPV_EXT_shader_atomic_float)
