# Autoresearch Ideas

## CURRENT STATUS: 180 passes, 0 compile errors, 17 spirv-val failures

### Remaining 17 spirv-val failures:
1. **newTexture.frag** — FAdd float+vec4 (swizzle `.x` dropped after texture call)
2. **spv.newTexture.frag** — Sampled Image type mismatch
3. **atomic.comp** — Undefined ID %110 (phantom ID)
4. **casts.comp** — OpCompositeConstruct constituents count (bvec4 from int)
5. **fp-atomic.nocompat.vk.comp** — AtomicIAdd on float (needs OpAtomicFAddEXT)
6. **generate_height.comp** — Duplicate ID (function overloading or other)
7. **ground.frag** — No OpEntryPoint (error recovery kills main function)
8. **mod.comp** — SRem on v4float (floatBitsToInt returns wrong type)
9. **partial-write-preserve.frag** — Duplicate IDs (function overloading)
10. **read-from-row-major-array.vert** — Constituents count for matrix construction
11. **sampler-ms-query.desktop.frag** — Image MS flag wrong
12. **shader_group_vote.comp** — ARB extension functions → Round (need OpGroupAll/Any)
13. **texture-proj-shadow.desktop.frag** — OpStore type mismatch (vec4 stored to float)
14. **texture-shadow-lod-bias.frag** — FAdd float+vec4 (shadow sampler returns vec4 not float)
15. **texture-shadow-lod.frag** — FAdd float+vec4 (same as above)
16. **torture-loop.comp** — Continue construct structural domination
17. **type-alias.comp** — Duplicate IDs (function overloading)

## HIGH PRIORITY

### Swizzle on function call results (affects 3+ files)
The `.` after function calls like `texture(sampler, coord).x` is tokenized as double_literal.
This causes vec4 to be used where float was expected (the `.x` is dropped).
Fix requires lexer change for bare `.` which has been tried 10+ times and always regresses.

### Function overloading (affects 3 files: partial-write-preserve, type-alias, generate_height)
Our compiler uses name-only lookup, so overloaded functions get duplicate IDs.
Need signature-based function resolution.

## MEDIUM PRIORITY

### Fix torture-loop.comp continue construct
Structural domination issue in loop control flow.

### Fix ground.frag No OpEntryPoint
The error recovery "break on error" kills the main function because `#if` preprocessor
doesn't recursively expand macros in expressions (e.g., `#if GLOBAL_RENDERER == DEFERRED`
where both are #defined constants).

### Shadow sampler texture functions return float not vec4
textureLod on sampler2DShadow should return float. Currently returns vec4.

## LOW PRIORITY

### Fix fp-atomic (needs SPV_EXT_shader_atomic_float)
### Fix sampler-ms-query (sampler2DMS type needs Multisampled=1)
### Fix casts.comp bvec4(int) — need int→bool conversion + splat
