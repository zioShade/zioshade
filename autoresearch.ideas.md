# Autoresearch Ideas Backlog

## Current State: 96 passes (up from 92 at session start, +4)

### Session Progress (92→96)
- image2DMS/image2DMSArray types + multisample image read/write (+1: image-ms.desktop.frag)
- Basic switch statement support (lexer+parser+no-op semantic) (+3: switch*.legacy files)

## High Priority (Spirv-Val Fixes - 6 remaining)
- **Phantom IDs** (2): spv.nvAtomicFp16Vec (float16), tensor_read (ARM tensors)
- **Forward refs** (1): struct-flatten-stores (struct type constructors)
- **Duplicate ID** (1): type-alias (function overloading)
- **Switch no-op fallout** (2): cfg.comp, cfg-preserve-parameter — files now compile but switch bodies skipped, causing type errors in SPIR-V

## Blocked: Swizzle/Lexer Fix (35+ compile errors)
The lexer tokenizes `.` followed by letters (e.g., `.xy`) as double_literal instead of dot. This blocks:
- 35 assign_op errors (v.x = ...)
- 8 compound_assign errors (v.x += ...)
- 6 index_access errors (gl_GlobalInvocationID.x)
- 5 binary_op errors (v.xy + ...)
- And many more (imageLoad, imageStore, texelFetch, modf, normalize, etc.)

Previous attempts to fix caused 92→67 regression. The fix requires:
1. Lexer: `.` not followed by digit → dot token
2. Semantic: proper CompositeExtract for single swizzle, VectorShuffle for multi
3. Semantic: proper l-value handling for swizzle writes (VectorInsertDynamic)

## Medium Priority (Other Compile Errors)
- **type_constructor** (6): Array constructors, struct constructors
- **Missing builtins** (20+): beginInvocationInterlockARB, rayQuery, subgroup ops, etc.
- **Missing image types**: image1D, imageCube, imageCubeArray, image3D, image2DArray

## Ideas for Next Session
- **Fix cfg.comp spirv-val failures**: The switch no-op means variables assigned in switch don't get values. Could emit default initializations.
- **Image type keywords**: Add image1D, image3D, imageCube, etc. Only image-query.desktop.frag uses them.
- **Function overloading**: type-alias.comp needs overload resolution.
