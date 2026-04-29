# Autoresearch: Maximize GLSL-to-SPIR-V Conformance

## Objective
Achieve functional equivalency with glslangValidator for the glslpp GLSL-to-SPIR-V compiler,
targeting replacement of the C++ glslang pipeline in the deblasis/wintty (windows branch) project.
The compiler must produce valid SPIR-V that matches glslang's output while potentially being faster/more compact.

## Current State (199/199 conformance)
- **199/199 spirv-val conformance** ✅
- **10/10 Ghostty shaders pass** ✅ (common.glsl is include-only, excluded)
- SPIR-V output ~0.73x glslang size (27% smaller)
- GL_EXT_buffer_reference support: PhysicalStorageBuffer pointers, OpTypeForwardPointer, access chain pointer loads, Aligned memory operands
- Proper std140/std430 layout: Block, Offset, ColMajor, MatrixStride, ArrayStride decorations
- StorageBuffer storage class for SSBOs (modern SPIR-V 1.1+ approach)
- Default DescriptorSet=0 for UBO/SSBO variables
- Compute shader LocalSize execution mode
- OpSource version detection from #version directive (GLSL/ESSL)
- 8/16-bit type support: Int8, Int16, Float16 capabilities
- Centroid/NoPerspective/Flat decorations for IO variables
- In/out block member scoping: only uniform/buffer/push_constant members are directly accessible
- SSA variable optimization, constant dedup, two-buffer on-demand codegen

## Metrics
- **Primary**: total_pass (unitless, higher is better) — total shaders passing spirv-val
- **Secondary**: total_compile_error, total_fail (spirv-val), total_skip, total_hang

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
- `src/parser.zig`: Pratt parser
- `src/semantic.zig`: Symbol resolution, type checking, IR emission
- `src/codegen.zig`: IR → SPIR-V binary emission
- `src/preprocessor.zig`: #define, #ifdef, macro expansion
- `src/lexer.zig`: Tokenizer
- `src/ast.zig`: AST node definitions, type system
- `src/ir.zig`: IR instruction tags and Module/Function/Global definitions
- `src/spirv.zig`: SPIR-V opcodes, capabilities, decorations

## Off Limits
- `src/root.zig` public API (`compileToSPIRV` signature) — don't break callers
- Don't run `zig build test` — causes OOM
- Don't modify the test shader files in tests/

## Constraints
- All changes must compile with Zig 0.15.2
- Must not introduce regressions on already-passing shaders

## Remaining for full glslang equivalency
- gl_PerVertex Block wrapping (structurally different, functionally equivalent — passes spirv-val without it)
- OpLine debug information
- Spec constant support
- Dead instruction/global elimination (size optimization)
