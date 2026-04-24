# Autoresearch Handoff Notes — Session 2

## Current State: 22 / 197 valid files pass

Run `bash autoresearch.sh` — takes ~4min, outputs METRIC lines.

### Breakdown
- 22 PASS, 132 compile_error, 43 spirv-val_fail, 0 hang, 0 crash
- Branch: `autoresearch/conformance-20260423` (latest commit f8acac1)
- 14 experiments logged in `autoresearch.jsonl`

## P0 Bug: UBO member access returns void type
When `uMVP` (uniform block member, mat4) is used in `uMVP * aVertex`:
- Debug showed: `analyzeExpression(uMVP)` returns `{ty=void, id=X}`
- The binary_op then gets `left=void right=vec4` → `promoteTypes(void,vec4)` → void
- Results in `OpIMul %void` in SPIR-V
- **Root cause**: The AST for the expression has a **nested binary_op** where `uMVP` should be. The `analyzeExpression(.identifier)` handler is never reached for `uMVP`.
- **Next step**: Dump the parser AST for `tests/spirv-cross/basic.vert` to understand the nesting. The parser may be producing unexpected structure for `gl_Position = uMVP * aVertex`.

## P1: 132 compile errors (all in semantic analysis)
Common causes:
- UndeclaredIdentifier (missing builtins/variables)
- TypeMismatch
- InvalidAssignment

## P2: 43 spirv-val failures
- Undefined IDs (block member access chains not properly emitted)
- Wrong result types (void where proper type expected)
- Interface variable not listed (in/out blocks)

## Architecture
- Pipeline: source → lexer.tokenize() → parser.parse() → semantic.analyze() → codegen.generate()
- compileToSPIRV catches all errors generically — can't see which sub-stage fails
- Semantic analysis is the bottleneck — ALL compile errors happen there
- The `block_member` symbol kind was added but may not be reached for all UBO access patterns

## Quick Wins for Next Session
1. **Dump AST** for `basic.vert` — understand parser output structure
2. **Categorize compile errors** — add error-type tracking to `autoresearch.sh`
3. **Fix `else => void` fallback** in `analyzeExpression` — many unhandled AST node types silently produce void, causing cascading failures
4. **Implement `texture()` built-in** — many shaders use it
5. **Implement switch statements** — parser/IR/codegen missing

## Key Files Modified
- `src/semantic.zig` — most changes (type system, block_member, builtins)
- `src/codegen.zig` — SPIR-V emission, OpVariable reordering
- `src/parser.zig` — in/out block parsing, synchronize fix
- `src/lexer.zig` — precision keyword, buffer/coherent/restrict/writeonly/readonly
- `src/ir.zig` — SPIRVStorageClass additions (private, input, output)
- `tests/runner.zig` — stage detection from file extension
- `src/root.zig` — public API (unchanged signature)

## Tools & Paths
- Zig: 0.15.2
- glslangValidator: `C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe`
- spirv-val: `C:\VulkanSDK\1.4.341.1\Bin\spirv-val.exe`
- Runner: `.zig-cache/o/*/conformance-runner.exe` (built via `zig build conformance -- nul`)
- Classification cache: `.zig-cache/ref_classification.txt`
- Build: `zig build conformance -- nul` (must pass `-- nul` to satisfy arg)
