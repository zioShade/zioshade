# value_dedup_collision + ubo_block_local_collision -- reproducers for zioshade-sid

## value_dedup_collision.spv (the bug)
Two VARIABLE ids whose `OpName`s sanitize to the same emitted string, one global
one function-local: `g` Input `OpName "a_b"` + `l` Function `OpName "a-b"`
(-> `a_b`). The function-local silently shadows the global -> `OpLoad %g` reads
the local instead of the input (plausible-but-wrong). spirv-cross DEDUPS the
same way (`a_b` -> `a_b_1`), so this is render-MATCH-certifiable vs spirv-cross.
After the fix the local is mangled to `a_b_1`.

## ubo_block_local_collision.spv (the regression guard)
A UBO block whose struct type AND instance are both `OpName "Globals"`, plus a
function-local also `OpName "Globals"` (compiled from GLSL via glslang):
```
layout(binding = 0) uniform Globals { float x; };   // type + instance both "Globals"
void main() { float Globals = 7.0; ... }            // local also "Globals"
```
The instance is emitted under a block-naming-mangled name (`Globals_1`), NOT its
raw OpName, so a local sharing the block's raw OpName does NOT shadow it. The fix
EXCLUDES block-decorated instances from the collision set, so the local keeps
`Globals` (it must NOT be mangled to `Globals_1`, which would collide with the
instance and break the UBO access). This guards against the regression a broader
all-OpName pass introduced (it mangled the local into the block-naming space).

## Verification
Both are render-MATCH-certified vs spirv-cross (spirv-cross dedups the same way)
and structurally asserted in `tests/glsl_tests.zig`. The fix is SCOPE-AWARE:
only function-scope-vs-global collisions silently shadow; type/variable overlaps
and block-named instances are left alone.
