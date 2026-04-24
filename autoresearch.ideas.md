# Autoresearch Ideas

## High Priority
- **Add more GLSL builtins**: `dot()`, `abs()`, `clamp()`, `min()`, `max()`, `mix()`, `step()`, `smoothstep()`, `length()`, `distance()`, `normalize()`, `reflect()`, `refract()`, `pow()`, `exp()`, `log()`, `sqrt()`, `inverse()`, `transpose()`, `determinant()`, `outerProduct()`. Many of the 47 generic SemanticFailed errors are from unknown builtins.
- **Add lvalue support for index_access and member_access**: `analyzeLValue` only handles `.identifier`. Need `.index_access` (arr[i] = x) and `.member_access` (struct.field = x) for 6+ compile errors. Be careful with pointer stability for array type base.
- **Add `flat`, `centroid`, `sample`, `noperspective` qualifiers**: in-block qualifiers need parsing. These are in the lexer as keywords but not in tryQualifier.

## Medium Priority
- **"Block must end with branch" (3 files)**: if_stmt/for_stmt inner analysis fails and skips OpBranch. Can't use catch{} (causes hangs). Root cause: inner expression analysis fails. Need to fix the underlying expression failures.
- **Implicit loads for variable access**: Variables (globals) return pointer IDs. Binary ops pass these pointers directly to SPIR-V instructions that expect values. Currently works because ext_inst builtins somehow auto-load. Need to verify and add loads where needed.
- **Array brackets in uniform block members**: `buffer SSBO { vec4 data[]; }` needs `[]` support. Reverted due to regression — unknown types like `int32_t` cause undefined IDs in SPIR-V. Need to handle unknown types gracefully.

## Low Priority
- **#include preprocessor**: Ghostty shaders need it, but classified as INVALID.
- **Switch statements**: 4 valid test files use switch. Needs OpSwitch + break-in-switch context.
- **Memory leaks in parser**: `self.alloc.create(ast.Type)` for array base types leaks.
- **Runtime arrays**: OpTypeRuntimeArray support added but not enabled (bracket parsing reverted).
