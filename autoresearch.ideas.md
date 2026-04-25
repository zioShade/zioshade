# Autoresearch Ideas Backlog

## High Priority (Spirv-Val Fixes - 6 remaining)

- **Phantom IDs** (3 files): `ensureType(.named)` returns an ID without emitting the type instruction. Need to fix named type emission to always emit before referencing.
  - spv.nvAtomicFp16Vec.frag: float16 types not emitted
  - int64.desktop.comp: int64 type not emitted
  - struct-packing.comp: named struct types not emitted as OpTypeStruct
  
- **OpTypePointer in wrong section** (1): struct-flatten-stores — pointer types emitted during function body. Pre-emit pointer types in emitTypesAndConstants.
  
- **image-ms.desktop.frag** (1): image2DMS uses rgba8 format but SPIR-V expects correct ImageFormat. The image type emission doesn't set the format from the layout qualifier.

- **type-alias.comp** (1): Function overloading — same function name with different parameter types produces duplicate IDs.

## Medium Priority (Compile Errors - 102)

- **Swizzle/Lexer fix** (54 assign_op errors): The `.` is tokenized as double_literal. Requires coordinated lexer + parser + semantic fix. Parser evaluation-order fix is DONE. Need: 1) Lexer: `.` not followed by digit → dot token 2) Semantic: proper CompositeExtract/VectorShuffle for swizzles. Previous attempts caused regressions (83→61). Need more careful approach.

- **Switch statements** (3 files): No parser support. Would need .kw_switch parsing, case/default handling, OpSwitch SPIR-V emission.

- **CFG/empty ctx** (7 files): Errors in analyzeStatement without errdefer context. Root cause unclear.

- **Missing builtins**: beginInvocationInterlockARB (4), rayQueryInitializeEXT (3), normalize (3), subgroupQuadAll (2), group (2), modf (2).

## Done This Session (83→89, +6 passes)

- iimage2d/uimage2d distinct types (+1: coherent-image.comp)
- sampler_buffer/image_buffer types (+1: texture_buffer.vert)
- OpImageSampleExplicitLod for textureLod (+1: explicit-lod.legacy.vert)
- Matrix-to-matrix conversion mat3(mat4) (+1: matrix-conversion.flatten.frag)
- Implicit LOD→explicit for vertex shaders + pre-emit constants (+1: implicit-lod.legacy.vert)
- OpVectorExtractDynamic for runtime vector indexing (+1: int-attribute.legacy.vert)
