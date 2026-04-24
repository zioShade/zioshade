# Autoresearch Ideas

## High Priority
- **Fix '.' lexer tokenization CAREFULLY**: `accum.y` tokenizes as identifier + double_literal + identifier because `.` alone is classified as double_literal. Fix: in tryParseNumber, only return non-null if has_digit=true. But this causes 22-pass regression — need to investigate WHY and fix the root cause before re-applying.
- **Add errdefer context to analyzeExpression**: Tag the AST node type when analyzeExpression fails. Then categorize the 115 compile errors by node type and fix the most common ones.
- **Implicit load for variable references**: When a global/local variable is used in an expression, its ID is a pointer. Need to insert OpLoad before using the value in arithmetic/comparison. Currently works for some builtins but not consistently.

## Medium Priority  
- **Add lvalue support for index_access and member_access**: `analyzeLValue` only handles `.identifier`. Need `.index_access` (arr[i] = x) and `.member_access` (struct.field = x). Be careful with pointer stability for array type base. 6+ compile errors.
- **Add `flat`, `centroid`, `sample`, `noperspective` qualifiers**: in-block qualifiers need parsing in tryQualifier.
- **Single-component swizzle (vec4.x)**: Currently returns phantom ID with no instruction. Need OpLoad + OpCompositeExtract. But causes regression when applied naively — needs investigation.
- **"Block must end with branch" (3 files)**: Root cause is if_stmt parsing failing (because `accum.y` tokenizes wrong → expression fails → parseIf fails → synchronize skips else → block only has expr_stmt). 

## Low Priority
- **#include preprocessor**: Ghostty shaders need it, classified as INVALID.
- **Switch statements**: 4 valid test files use switch. Needs OpSwitch.
- **Array brackets in uniform blocks**: `buffer SSBO { vec4 data[]; }` needs [] support. Reverted twice due to regressions.
