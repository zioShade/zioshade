# Autoresearch Ideas — glslpp Feature Coverage

## STATUS: 213/222 pass (95.9%), 0 val_fail ✅
## HLSL tests: 101/101 pass, 0 fail, 0 leak ✅
## Session: 208→213/222 conformance (+5), HLSL 76→101 (+25 tests)

## ⚠️ Test additions are approaching natural coverage limit
## Further HLSL test additions should only cover genuinely NEW functionality.

## Remaining 9 SKIP (error validation tests — not fixable)
These test that the compiler rejects invalid GLSL. Would need error detection/reporting.

## Bugs Found During Testing
- Parser leaks memory when creating array types (e.g., `shared float s_data[64]`)
  - parser.zig:708 — `try self.alloc.create(ast.Type)` never freed
  - The AST tree is not properly cleaned up in the test harness

## Potential Future Work
- Fix parser array type memory leak
- Add sampler2D texture sampling HLSL test with assertion on `Sample()` output
- Add image load/store HLSL test
- Add geometry shader passthrough test
- Add gl_FragDepth test
- Build dominator tree for proper cross-block forwarding in constStoreForward
