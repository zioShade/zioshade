# Autoresearch Ideas

## High Priority (unblock many files)
- **Register GL builtins as global variables**: gl_Position, gl_FragCoord, gl_FragColor, gl_Layer, etc. need to be registered as proper globals with Input/Output storage class, not just symbols. Without this, assignments to gl_Position produce undefined IDs.
- **Fix UBO member access chains**: The access chain + load pattern for block members may have issues with ID allocation or instruction emission order. Need to verify the SPIR-V output.
- **OpIMul %void bug**: The `uMVP * aVertex` produces OpIMul with void result type. Either the binary_op handler is getting wrong types, or the type resolution in codegen is failing for access chain results.

## Medium Priority
- **Buffer blocks (SSBOs)**: `buffer` keyword is parsed but not handled in semantic analysis for storage buffer storage class.
- **Interface blocks (in/out blocks)**: `in BlockName { ... } name;` needs parsing and end-to-end support.
- **Switch statements**: Parser support needed, then IR + codegen.
- **#include preprocessor**: Needed for Ghostty shaders. Read included file relative to current file.
- **local_size_x for compute**: Parse `layout(local_size_x = N) in;` and emit OpExecutionMode LocalSize.

## Low Priority
- **Precision qualifiers**: `mediump`/`lowp`/`highp` — skip for now, they don't affect SPIR-V correctness.
- **Memory leaks in parser dupeNodes**: Non-crashing but GPA reports leaks.
- **Multiple variable declarations**: `float a, b;` — not parsed.
