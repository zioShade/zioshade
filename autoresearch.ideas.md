# Autoresearch Ideas

## High Priority
- **Fix parser evaluation-order bug (DONE)**: `makeBinaryOp` helper fixes corrupted AST for all binary expressions. This was the biggest single fix (+2 passes, +correct SPIR-V for many more).
- **Matrix/vector multiply ops (DONE)**: Use OpMatrixTimesVector, OpVectorTimesScalar etc. instead of FMul.
- **Texture() return type (DONE)**: Always vec4, not sampler type.

## Medium Priority
- **Interface block parsing regression**: Parsing `out Name { ... } inst;` before tryType() causes "Id is 0" errors in SPIR-V. The old synchronize()-based approach accidentally works for simple blocks (one member, no instance name). Root cause: the `uniform_block` → `block_member` → access_chain path produces wrong SPIR-V (ID 0 somewhere). Need to debug the access chain codegen for block members.
- **"Block must end with branch" (5 files)**: If/else or for-loop blocks missing termination instruction. Likely a missing OpBranch after block body in codegen.
- **OpVariable not first in block**: Already fixed (OpVariable reordering). But some blocks may still have issues with mixed local vars and instructions.
- **Implement switch statements**: Parser/IR/codegen missing. Several test files use switch.
- **CompositeConstruct wrong constituents (2 files)**: TypeConstructor emitting wrong operand types.

## Low Priority
- **#include preprocessor**: Ghostty shaders need it, but they're classified as INVALID by glslangValidator anyway.
- **Precision qualifiers**: Skip — doesn't affect SPIR-V correctness.
- **Memory leaks in parser dupeNodes**: Non-crashing but GPA reports.
