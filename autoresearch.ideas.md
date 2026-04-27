# Autoresearch Ideas

## CURRENT STATUS: 192 passes, 0 compile errors, 5 spirv-val failures

### Remaining 5 spirv-val failures:
1. **spv.newTexture.frag** — Integer samplers (isampler2D etc) treated as sampler2D. Need full integer sampler type system. Complex refactor.
2. **atomic.comp** — Phantom ID %110 from imageAtomicAdd inside ivec4(imageAtomicAdd(...)). The texel pointer + atomic instructions aren't being emitted for the nested call. Debug needed.
3. **fp-atomic.nocompat.vk.comp** — AtomicIAdd on float (needs OpAtomicFAddEXT or similar)
4. **ground.frag** — No OpEntryPoint. Preprocessor #if works in standalone test but not in runner binary. Mystery discrepancy between standalone test (559 words, has main) and runner binary (no functions). Possibly a Zig caching or compilation unit issue.
5. **texture-proj-shadow.desktop.frag** — sampler1D mapped to sampler2D causes coordinate dimension mismatch for textureProj

### Key insights:
- The runner binary produces different results than standalone test with same source — UNEXLORED ROOT CAUSE
- Integer sampler support requires adding ~20 new AST types + codegen — attempted but reverted due to regressions
- The preprocessor == fix is correct but doesn't fix ground.frag
- Image atomics need OpImageTexelPointer before OpAtomic* — partially implemented

### Completed this session:
- GPA leak fix in overload map deinit (+1)
- Pack/unpack return type fix (+1)
- textureGather/textureGatherDref (+1)
- Preprocessor == operator fix (no pass change)
- Image atomic operation framework (WIP, not yet working)
