# Autoresearch Ideas Backlog

## Current State: 98 passes (up from 92 at session start, +6 total)
- Session: 92→93 (image-ms) → 96 (switch no-op) → 97 (matrix column index) → 98 (struct type pre-emit)
- Remaining: 95 compile errors, 4 spirv-val failures, 0 hangs, 0 crashes

## Session Wins
- image2DMS/image2DMSArray types + multisample image read/write (+1)
- Basic switch statement support (lexer+parser+no-op semantic) (+3)
- Matrix column indexing via OpCompositeExtract (+1)
- Pre-emit all named struct types from module.types (+1, -2 spirv-val)
- Added errdefer in analyzeStatement for better error diagnostics

## Failed Experiments
- **Parser-level swizzle detection** (96→64): Treating '.' + identifier as member_access cascades into crashes. Semantic handler not robust enough.
- **Lexer fix: bare '.' as dot** (96→64): Same root cause — semantic can't handle all new member_access nodes.
- **Invocation interlock + atomic builtins** (96, no change): Complex implementation that didn't help any files pass (interlock files also need atomicAnd, buffer atomics).
- All 3 swizzle attempts failed. The semantic member_access handler must be fixed FIRST.

## Spirv-Val Failures (4 remaining)
1. **cfg.comp**: "A block must end with a branch instruction" — switch no-op fallout
2. **cfg-preserve-parameter.comp**: "OpStore type for pointer is not a pointer type" — switch no-op
3. **struct-flatten-stores-multi-dimension.legacy.vert**: Forward-referenced IDs (60-62) — semantic type IDs don't match codegen IDs
4. **type-alias.comp**: "Id 63 is defined more than once" — function overloading not supported

## High-Impact Opportunities
### Swizzle Fix (BLOCKS ~50 compile errors)
The #1 opportunity. Requires:
1. Fix semantic `member_access` handler for ALL cases (struct fields, swizzle reads, swizzle writes, vector components)
2. Fix `analyzeLValue` for swizzle writes (v.x = val)
3. THEN fix lexer to tokenize bare '.' as dot (not double_literal)
4. Verify no crashes or regressions on existing 98 passing files

### Easy Wins (if any remain)
- Add missing image types (image1D, imageCube, etc.) — only affects image-query.desktop.frag
- row_major/column_major layout qualifier — only affects rowmajor.flatten.vert
- Float16 types (half) — only affects spv.nvAtomicFp16Vec.frag

## Medium Priority
- Struct type ID alignment (semantic vs codegen) — fixes struct-flatten-stores
- Proper switch statement OpSwitch emission — fixes cfg.comp/cfg-preserve-parameter
- Function overloading — fixes type-alias.comp
- Output parameter support — fixes flush_params.frag, partial-write-preserve.frag
- Array type constructors (vec4[](...)) — fixes constant-array.frag, return-array.vert
