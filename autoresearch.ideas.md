# Autoresearch Ideas Backlog

## Current State: 98 passes (from 92 at session start, +6 total)

## Session Progress (92→98)
- image2DMS/image2DMSArray types + multisample image read/write (+1)
- Basic switch statement support (lexer+parser+no-op semantic) (+3)
- Matrix column indexing via OpCompositeExtract (+1)
- Pre-emit all named struct types from module.types (+1, -2 spirv-val)
- Push constant storage class + member ptr pre-emit + array type dedup (0, infrastructure)

## Swizzle Fix — BLOCKED (4 failed attempts)
The #1 opportunity but requires fixing the semantic handler FIRST. The problem:
- 4 attempts all regressed 98→74 or 98→76
- Root cause: changing lexer/parser creates member_access nodes that the semantic can't handle
- The "Invalid free" crashes come from l-value handling of nested member_access
- Many previously-passing files RELY on `.` being hidden as double_literal
- Need to make semantic handle ALL member_access cases before changing lexer/parser

## Remaining Wins
### Spirv-Val (4)
1. **cfg.comp / cfg-preserve-parameter.comp**: Switch no-op structural issues
2. **struct-flatten-stores-multi-dimension.legacy.vert**: Phantom IDs
3. **type-alias.comp**: Function overloading

### Compile Errors (95)
- 63/95 are swizzle-related (undeclared identifiers from `.xy` patterns)
- 10/95 are swizzle write related (assign_op inner=assign_op)
- Remaining: missing builtins, unsupported types, complex features

## Infrastructure Added
- Push constant storage class detection in semantic
- Array type dedup cache in codegen
- Member pointer type pre-emission for struct members
- isSwizzleName helper + proper vector swizzle semantic code (dormant, needs lexer fix)
