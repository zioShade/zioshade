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

## HIGH PRIORITY

### Shadow sampler texture functions return float not vec4 (affects 3+ files)
textureLod/textureOffset on sampler2DShadow etc. should return float, not vec4.
**Blocker**: shadow sampler types (sampler2DShadow, etc.) are all parsed as .sampler2d in the parser.
Need to either: (a) add distinct shadow sampler types, or (b) track "shadow" flag separately.

### Swizzle on function call results (affects 4+ files including newTexture, texture-proj-shadow)
The `.` after function calls like `texture(sampler, coord).x` is tokenized as double_literal.
This causes vec4 to be used where float was expected (the `.x` is dropped).
Fix requires lexer change for bare `.` which has been tried 10+ times and always regresses.
**Previous attempts**: Always regress because the semantic analyzer can't handle the flood of new member_access nodes.
Need arena-based error recovery for safe semantic error handling.

### Function overloading (affects 3 files: partial-write-preserve, type-alias, generate_height)
Our compiler uses name-only lookup, so overloaded functions get duplicate IDs.
Need signature-based function resolution.

## MEDIUM PRIORITY

### Fix integer sampler types (isampler2D, usampler2D → int/uint sampled type)
Currently parsed as .sampler2d, but SPIR-V TypeImage needs int/uint sampled type.
Affects spv.newTexture.frag.

### Fix torture-loop.comp continue construct
Structural domination issue in loop control flow.

### Fix ground.frag No OpEntryPoint
The preprocessor already has single-level macro resolution for #if.
Needs multi-level: `#if GLOBAL_RENDERER == DEFERRED` → resolve GLOBAL_RENDERER→DEFERRED→1, DEFERRED→1, then evaluate.

### Fix atomic.comp phantom IDs
imageAtomicAdd etc. on image types need proper image variable handling.

## LOW PRIORITY

### Fix fp-atomic (needs SPV_EXT_shader_atomic_float)
### Fix complex-expression-in-access-chain.frag (was regressed by MS image_fetch, now fixed)
