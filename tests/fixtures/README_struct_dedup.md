# struct_dedup_collision -- reproducer for zioshade-zm0

Two `OpTypeStruct` sharing one `OpName` `"S"` with **different** layouts:

- `DA = OpTypeStruct %v4f`            -- `{ vec4 }`
- `DB = OpTypeStruct %float %float %float %float` -- `{ f, f, f, f }`

This is **legal SPIR-V** (OpName is a debug name; two types may share it).
spirv-cross (the reference) handles it by mangling the second to `S_1`.

## The bug (#zm0)

zioshade's struct forward-decl emitter
(`commonEmitOneStructForwardDecl` / `hlslEmitOneStructForwardDecl`) dedups by
**name** as well as by type id. Two distinct type ids sharing one OpName
collapse: the second struct's real layout is **never emitted**, so uses of it
compile against the **first** struct's definition. Where the layouts overlap
compatibly (e.g. std140 UBO byte offsets), reads/writes silently bind the wrong
bytes -- plausible-but-wrong (a mandate violation). glslang cannot catch the
silent binding; only render-diff can.

This fixture's in-member-count shape surfaces as the loud form (an undeclared
member `m2`), which is what makes it a convenient compile-level regression
guard; the underlying hazard is the silent binding.

## The fix

A one-time pre-pass (`commonPrewriteUniqueStructNames`, run after `collectNames`
and before any struct forward-decl emission) rewrites colliding struct names in
`names` to a unique mangled form `S -> S_1 -> S_2` (matching spirv-cross), so
the existing emitter never drops a distinct type. Non-colliding structs are
untouched. Applied to both the GLSL and HLSL backends (both feed the shared
pre-pass; HLSL mangles on the `hlslSafeName` form).

## Verify

```
spirv-as struct_dedup_collision.spvasm -o struct_dedup_collision.spv
spirv-val struct_dedup_collision.spv                       # legal
zioshade glsl struct_dedup_collision.spv                    # emits BOTH S and S_1
# render-MATCH vs spirv-cross (tools/glsl_render_check_spv.sh): outColor = (7,7,7,1)
```

The structural assertion (both `struct S` and `struct S_1` declared, `float m2;`
present) is encoded in `tests/glsl_tests.zig` so a revert of the pre-pass fails
`zig build test` / CI.
