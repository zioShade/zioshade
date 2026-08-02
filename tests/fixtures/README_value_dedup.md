# value_dedup_collision -- reproducer for zioshade-sid

Two **variable** ids whose `OpName`s sanitize to the same emitted string, one
global one function-local:

- `g = OpVariable ... Input`, `OpName "a_b"`  -> sanitizeName -> `a_b`
- `l = OpVariable ... Function`, `OpName "a-b"` -> sanitizeName -> `a_b` (dash -> _)

Both become `a_b`. The function-local **silently shadows** the global, so
`OpLoad %g` (which must read the input) instead reads the local -> plausible-
but-wrong (a mandate violation). This is the sanitize-to-same-string collision
class documented at `spirv_to_glsl.zig` (sanitizeName) and tracked as #sid.

## Verification caveat (why not render-MATCH)

spirv-cross **shares** the collision (it emits the same shadowing code), so the
spirv-cross render-proxy shows a correlated MATCH and cannot certify the fix.
This fixture is verified by **name-distinctness** (the local is mangled to
`a_b_1`, so no shadow is possible) plus the known semantics (`OpLoad %g` must
read `%g`) -- and a structural regression test in `tests/glsl_tests.zig` asserts
the mangled local is present (absent pre-fix, when both ids collapse to `a_b`).

## The fix (#sid) -- scope-aware, narrow

A one-time pre-pass `commonPrewriteUniqueValueNames`-style helper
(`commonPrewriteUniqueLocalVarNames`) mangles ONLY a function-local variable
whose sanitized name collides with a **global variable**'s name (the only
collision that silently shadows). Same-scope local/local collisions are loud
redefinitions (caught by the target compiler); type/type and type/variable
overlaps (e.g. a UBO struct type and its instance variable both `OpName
"Globals"`) are handled by the backends' existing block naming and are left
ALONE -- a broader all-OpName uniqueness pass regressed exactly those. Applied
to GLSL and HLSL.

## Reproduce

```
spirv-as value_dedup_collision.spvasm -o value_dedup_collision.spv
spirv-val value_dedup_collision.spv                 # legal
zioshade glsl value_dedup_collision.spv              # input keeps "a_b"; local mangled to "a_b_1"
```
