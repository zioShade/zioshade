# Autoresearch: Maximize GLSL-to-SPIR-V Conformance

## Objective
Achieve functional equivalency with glslangValidator for the glslpp GLSL-to-SPIR-V compiler,
targeting replacement of the C++ glslang pipeline in the deblasis/wintty (windows branch) project.
The compiler must produce valid SPIR-V that matches glslang's output while potentially being faster/more compact.
Maintaining 197/197 spirv-val conformance is a hard requirement.

## Current State (197/199 conformance)
- 197/199 spirv-val conformance ✅
- 8/9 Ghostty shaders pass (cell_text.v.glsl fails spirv-val; common.glsl is include-only, excluded)
- GL_EXT_buffer_reference support: PhysicalStorageBuffer pointers, OpTypeForwardPointer, access chain pointer loads, Aligned memory operands
- Proper std140/std430 layout: Block, Offset, ColMajor, MatrixStride, ArrayStride decorations
- StorageBuffer storage class for SSBOs (modern SPIR-V 1.1+ approach)
- Default DescriptorSet=0 for UBO/SSBO variables
- Compute shader LocalSize execution mode
- OpSource version detection from #version directive
- ESSL detection: emit OpSource ESSL for #version N es
- Bound optimization: ~0.72x glslang (28% smaller)

## Remaining 2 failures
- buffer-reference-bitcast-uvec2-2: PhysicalStorageBuffer pointer → uvec2 conversion (needs OpConvertPtrToU)
- small-storage.vk.vert: 8/16-bit types (needs Int8, Int16, Float16 SPIR-V types)

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
- gl_PerVertex Block wrapping (structurally different, functionally equivalent)
- SPIR-V version detection from #version directive
- Centroid/NoPerspective decorations for IO variables
