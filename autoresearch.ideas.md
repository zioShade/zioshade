# Autoresearch Ideas Backlog

## High Priority (Spirv-Val Fixes - 5 remaining)

- **Phantom IDs** (2): spv.nvAtomicFp16Vec (float16 types), tensor_read.nocompat.noopt.vk.comp
- **OpTypePointer in wrong section** (1): struct-flatten-stores — pointer types emitted during function body
- **Image type** (1): image-ms.desktop.frag — image2DMS ImageFormat mismatch
- **Duplicate ID** (1): type-alias.comp — function overloading

## Medium Priority (Compile Errors - 100)

- **Swizzle/Lexer fix** (54 assign_op errors): Requires coordinated lexer + parser + semantic fix.
- **Switch statements** (3 files): No parser support.
- **CFG/empty ctx** (7 files): Errors in analyzeStatement without errdefer context.
- **Missing builtins**: beginInvocationInterlockARB (4), rayQueryInitializeEXT (3), normalize (3), subgroupQuadAll (2), modf (2).
- **Missing image type keywords**: image1D, imageCubeArray, etc. parsed as identifiers instead of proper types.

## Done This Session (83→92, +9 passes)

- iimage2d/uimage2d distinct types (+1: coherent-image.comp)
- sampler_buffer/image_buffer types + texelFetch (+1: texture_buffer.vert)
- OpImageSampleExplicitLod for textureLod (+1: explicit-lod.legacy.vert)
- Matrix-to-matrix conversion mat3(mat4) (+1: matrix-conversion.flatten.frag)
- Implicit LOD→explicit for vertex shaders (+1: implicit-lod.legacy.vert)
- OpVectorExtractDynamic for runtime vector indexing (+1: int-attribute.legacy.vert)
- Array-size suffix in struct/uniform block members (+3: struct-packing.comp + 2 more)
