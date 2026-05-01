# Autoresearch Ideas — glslpp

## STATUS: 199/199 spirv-val, 196/199 exact matches (98.5%), 149/149 gap tests
## Commit: 7151699 (Ray query + constant_bool dedup)

## CURRENT METRICS:
- 199/199 spirv-val ✅
- 196/199 exact output store matches (98.5%)
- 3 remaining mismatches (ALL ARM tensor vendor extension)
- 0 failures (was 6)
- 149/149 gap tests ✅

## REMAINING GAPS (3 shaders):
1. tensor.nocompat.noopt.vk.frag (out=0/1) — tensorARM<uint8_t,3> type + tensorSizeARM/tensorReadARM
2. tensor_params.nocompat.invalid.vk.comp (buf=0/1) — tensorARM<int32_t,4> + tensorSizeARM with function params
3. tensor_read.nocompat.noopt.vk.comp (buf=0/1) — tensorReadARM with OutOfBoundsValueARM

## ARM TENSOR IMPLEMENTATION PLAN:
- SPIR-V opcodes: TypeTensorARM=4163, TensorReadARM=4164, TensorQuerySizeARM=4166
- Capability: TensorsARM=4174, Extension: SPV_ARM_tensors
- Parser: Add tensorARM keyword, parse template-like syntax tensorARM<type, N>
- Semantic: tensorARM as named type with element_type and rank
- Codegen: OpTypeTensorARM elem_type rank_constant
- Builtins: tensorSizeARM(tensor, dim) → OpTensorQuerySizeARM, tensorReadARM(tensor, coords, out) → OpTensorReadARM
- Complexity: HIGH — template syntax, new type system, multiple SPIR-V ops

## FEATURES COMPLETED THIS SESSION:
- nonuniformEXT() passthrough (1 shader, 14 stores)
- GL_QCOM_image_processing (4 shaders, 8 stores): box-filter, block-match-sad/ssd, sample-weighted
- GL_EXT_ray_query (1 shader, 1 store): accelerationStructureEXT, rayQueryEXT types, 4 builtins
- constant_bool dedup fix (was emitting OpConstantTrue/False with duplicate IDs)
- isTypeKeyword expanded for all sampler/image/texture types

## STRUCTURAL MISMATCHES (5, not bugs):
- Different implementation patterns (SSA vs memory, VectorShuffle vs AccessChain)
- Functionally equivalent outputs
