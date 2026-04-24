# Autoresearch Handoff Notes — Session 3

## Current State: 29 / 197 valid files pass

Run `bash autoresearch.sh` — takes ~5min, outputs METRIC lines.

### Breakdown
- 29 PASS, 132 compile_error, 36 spirv-val_fail, 0 hang, 0 crash
- Branch: `autoresearch/conformance-20260423` (latest commit ce97b39)
- 19 experiments logged in `autoresearch.jsonl`

## Key Fixes This Session (22→29)
1. **Parser evaluation-order bug**: `makeBinaryOp()` helper fixes Zig 0.15.2 issue where `left = .{ .children = dupeNodes(&.{left, right}) }` corrupts AST by reading `left` after assignment. Affected ALL binary expressions! (+2 pass, +correct SPIR-V for many more)
2. **Matrix/vector multiply ops**: OpMatrixTimesVector, OpVectorTimesScalar, etc. (+2 pass)
3. **Texture() return type**: Always vec4, not sampler type. (+2 pass)
4. **Uniform storage in OpEntryPoint**: Added Uniform storage class globals to interface list. (+1 pass)

## Top spirv-val Failure Categories (36 total)
- 5 "block must end with branch" — if/for blocks missing OpBranch
- 7 "interface variable not listed" — variables not in OpEntryPoint
- 2 "Constituents type mismatch" — CompositeConstruct wrong types
- 3 "Operand requires previous definition" — undefined IDs
- 2 "execution model" — wrong stage
- Others: various individual issues

## Top Compile Error Categories (132 total)
- All errors are in semantic analysis stage
- Missing features: switch statements (4 files), proper uniform block handling
- The parser's synchronize() accidentally parses single-member uniform blocks correctly

## Architecture Notes
- Pipeline: source → lexer → parser → semantic → codegen → SPIR-V
- `synchronize()` stops at `kw_uniform` — this accidentally causes single-member uniform blocks to be parsed as standalone uniform_decl (which works!)
- The `makeBinaryOp` fix affects ALL binary expressions — the parser was producing corrupted ASTs before
- The `else => void` fallback in analyzeExpression silently returns void for unhandled node types
- `block_member` symbol kind was added but the access chain path has bugs (produces "Id is 0")

## Quick Wins for Next Session
1. **Fix "block must end with branch" (5 files)**: Likely a missing OpBranch in if/for codegen
2. **Implement proper switch statements**: Needs lexer tokens, parser, semantic OpSwitch, break handling in switch context
3. **Fix interface variable listing (7 files)**: Some variables with Input/Output storage class not being listed
4. **Fix `else => void` fallback**: Many unhandled AST node types silently produce void
5. **Categorize the 132 compile errors**: Add error-type tracking to understand what's blocking

## Tools & Paths
- Zig: 0.15.2
- glslangValidator: `C:/VulkanSDK/1.4.341.1/Bin/glslangValidator.exe`
- spirv-val: `C:\VulkanSDK\1.4.341.1\Bin\spirv-val.exe`
- Runner: `.zig-cache/o/*/conformance-runner.exe`
- Build: `zig build conformance -- nul`
