# glslpp Polish & Real-World Testing — Design Spec

**Date:** 2026-05-22
**Status:** Draft
**Scope:** All improvements beyond the core compilation/cross-compilation features

## Background

glslpp is functionally complete: 1811/1811 conformance, 180/180 WGSL, 51/51 cross-validation, 50K fuzz iterations crash-free. But it has the rough edges of a project built through rapid iteration — stale docs, no CLI, weak error reporting, leaking internal APIs, and no real-world validation beyond synthetic tests.

This spec covers six workstreams, ordered by impact on a new user encountering the project for the first time.

---

## Workstream 1: README Overhaul

**Problem:** The README is actively misleading. It says GLSL and MSL backends are "planned" when they ship. It omits WGSL entirely. Conformance numbers are from an old run (548/566). The API table is missing 7+ public functions.

**Solution:** Rewrite README to reflect current state.

### What changes

- **Features section:** List all 4 cross-compilation targets (HLSL, GLSL, MSL, WGSL) as ✅, not planned
- **Conformance numbers:** Update to 1811/1811 + mention spirv-val, DXC, naga validation
- **API table:** Add `spirvToGLSL`, `spirvToMSL`, `spirvToWGSL`, `compileGlslToMsl`, `compileGlslToGlsl`, `reflectSPIRV`, `reflectGLSL`, `validateSPIRV`, `linkSPIRVModules`, `compileMultiKernel`, `compileToSPIRVWithFusion`
- **Quick Start:** Add a CLI usage example once the CLI tool exists (Workstream 3)
- **Shader stages table:** Mark mesh/task as ❌, add ray tracing stages
- **Performance:** Update benchmark numbers if re-run

### Files
- `README.md` — complete rewrite, same structure

---

## Workstream 2: Public API Cleanup & Documentation

**Problem:** 18 modules are `pub` in root.zig — lexer, ast, ir, preprocessor, etc. — exposing internal implementation details. No doc comments on options structs. Error handling uses a threadlocal global (`last_compile_detail`). Some convenience functions are missing.

### 2a: Doc comments on all public types and functions

Add `///` doc comments to every public type and function in `src/root.zig`:
- `CompileOptions` — document each field (what GLSL versions are valid, what spirv_version means)
- `HlslCompileOptions` — document `binding_shift` semantics (negative shifts left, positive shifts right)
- `GlslCompileOptions` — document `version` (330, 410, 430, 450, 460) and `es` (ESSL mode)
- `MslCompileOptions` — document `metal_version` (what versions are valid)
- `WgslCompileOptions` — note it's empty now, future options placeholder
- `CrossCompileOptions` — ✅ REMOVED (2026-06-01): was unused by any public function and its `flatten_ubos` field did nothing (phantom capability). Per-backend options structs are the real knobs; descriptor remap is `resource_bindings` on HLSL/MSL options.
- `ResourceLimits` — document what the limits control
- All public functions — one-line description + parameter docs

### 2b: Reduce public surface area

Keep as `pub` in root.zig only what users need:
- ✅ Keep: `Stage`, `SPIRVVersion`, `CompileOptions`, `ResourceLimits`, `Error` (CrossCompileOptions removed 2026-06-01 — dead/phantom)
- ✅ Keep: `compileToSPIRV`, `compileToSPIRVNoOpt`, `compileToSPIRVWithDiagnostics`, `spirvToHLSL`, `spirvToGLSL`, `spirvToMSL`, `spirvToWGSL`
- ✅ Keep: `compileGlslToHlsl`, `compileGlslToMsl`, `compileGlslToGlsl`, `compileGlslToGlslVersion`, `compileShadertoyToHlsl`
- ✅ Keep: `reflectSPIRV`, `reflectGLSL`, `validateSPIRV`, `linkSPIRVModules`, `compileMultiKernel`, `compileToSPIRVWithFusion`
- ✅ Keep: `diagnostic.Diagnostic` (used by `compileToSPIRVWithDiagnostics`)
- ✅ Keep: `reflection.ShaderResources`, `reflection.Resource`, `reflection.EntryPoint` (returned by reflect functions)
- 🔒 Make internal: `lexer`, `preprocessor`, `ast`, `ir`, `spirv`, `parser`, `semantic`, `codegen`, `compat`, `kernel_fusion`
- ⚠️ `reflection` and `diagnostic` — keep the types public, but consider whether re-exporting them from root.zig is cleaner than requiring `glslpp.reflection.Resource`

**Implementation:** Change `pub const lexer = @import("lexer.zig")` to `const lexer = @import("lexer.zig")` for internal modules. If any downstream code (wintty) uses these, coordinate the migration.

### 2c: Add missing convenience functions

Add `compileGlslToWgsl()` — the only backend missing a one-shot function:
```zig
pub fn compileGlslToWgsl(
    alloc: std.mem.Allocator,
    glsl_source: [:0]const u8,
    stage: Stage,
) ![:0]const u8
```

### 2d: Deprecate threadlocal error state

The `last_compile_detail` threadlocal is a code smell. Long-term, errors should be returned via a diagnostics struct. For now:
- Add a doc comment marking it as deprecated, pointing to `compileToSPIRVWithDiagnostics`
- Do NOT remove it yet (breaking change)

### Files
- `src/root.zig` — doc comments, visibility changes, new function

---

## Workstream 3: CLI Tool

**Problem:** There is no way to use glslpp from the command line. A new user who just wants to compile a shader has to write Zig code. This is a significant adoption barrier.

### Architecture

A single `src/cli.zig` file, built as an executable via `build.zig`. The CLI is thin — it calls the library, it doesn't implement anything.

### Usage

```bash
# Compile GLSL to SPIR-V binary
glslpp compile shader.frag -o shader.spv

# Cross-compile to HLSL
glslpp hlsl shader.frag -o shader.hlsl

# Cross-compile to GLSL (round-trip)
glslpp glsl shader.frag -o shader.glsl --glsl-version 450

# Cross-compile to MSL
glslpp msl shader.frag -o shader.msl

# Cross-compile to WGSL
glslpp wgsl shader.frag -o shader.wgsl

# Reflect on SPIR-V binary
glslpp reflect shader.spv

# Validate SPIR-V binary (via spirv-val)
glslpp validate shader.spv

# Auto-detect stage from extension
# .frag → fragment, .vert → vertex, .comp → compute, .geom → geometry, .tesc/.tese → tessellation
```

### CLI design decisions

- **Simple arg parsing:** No external dependency. Manual `argsAlloc` + linear scan. The CLI has ~10 commands, not worth a parser framework.
- **Stage detection:** From file extension by default, overridable with `--stage vertex`.
- **Output:** Write to file with `-o`, or stdout if no `-o`.
- **Error format:** `file:line:col: error: message` (GCC/Clang compatible).
- **Exit codes:** 0 = success, 1 = compilation error, 2 = invalid args.

### Files
- `src/cli.zig` — new file (~200-300 lines)
- `build.zig` — add `glslpp-cli` executable target

---

## Workstream 4: Error Handling Improvement

**Problem:** `compileToSPIRV` returns `error.ParseFailed` with no line/column/message. The user must check `last_compile_detail` (threadlocal) and `semantic.last_error_line`. Cross-compilation errors are opaque.

### 4a: Structured error return

Create a `CompileResult` type that bundles the output with diagnostics:
```zig
pub const CompileResult = struct {
    output: []const u32,  // or []const u8 for cross-compilation
    diagnostics: []const diagnostic.Diagnostic,
    
    pub fn deinit(self: *CompileResult, alloc: std.mem.Allocator) void { ... }
};
```

This is a **future** change — don't implement yet. The current API works, and changing return types is breaking. Document it as a planned v2 API.

### 4b: Improve error messages now (non-breaking)

Without changing the API, improve the error messages that are emitted:
- Semantic errors: include the actual expression/type that failed in the message
- Parse errors: include the unexpected token and what was expected
- Cross-compilation errors: include *which* opcode or construct is unsupported, not just "CrossCompileUnsupported"

This is purely internal work in `src/semantic.zig`, `src/parser.zig`, and the cross-compilation backends.

### 4c: Document the error pattern

Add a section to README showing how to handle errors properly:
```zig
const result = glslpp.compileToSPIRV(alloc, source, .{.stage = .fragment});
if (result) |words| {
    // success
} else |err| {
    std.debug.print("Error: {} ({s})\n", .{err, @tagName(glslpp.last_compile_detail orelse .codegen_failed)});
    if (glslpp.last_compile_detail) |d| {
        // check semantic.last_error_line for location
    }
}
```

### Files
- `src/semantic.zig` — better error messages
- `src/parser.zig` — better error messages
- `src/spirv_to_*.zig` — better error messages
- `README.md` — error handling section

---

## Workstream 5: Real-World WGSL Validation Pipeline

**Problem:** All 180 WGSL tests are synthetic (hand-written stress tests). We need to validate that glslpp produces *valid* WGSL when fed real shaders from real projects.

### Architecture

A test runner script (`tools/realworld_wgsl_test.sh` or Zig test) that:
1. Fetches GLSL shader collections from known repos
2. Compiles each through glslpp: GLSL → SPIR-V → WGSL
3. Validates WGSL output through naga/tint
4. Reports pass/fail with categorization of failures

### Shader sources (priority order)

1. **wgpu examples** (~50 shaders) — GLSL shaders from wgpu-rs examples. Small, well-structured, real WebGPU use cases. URL: `https://github.com/gfx-rs/wgpu/tree/master/examples`
2. **Bevy engine** (~200 shaders) — PBR, sprites, UI, post-processing. More complex patterns. URL: `https://github.com/bevyengine/bevy/tree/main/assets/shaders`
3. **WebGPU CTS** — Official conformance test suite. Complex to extract, but highest authority. URL: `https://github.com/webgpu/cts`
4. **Shadertoy demos** — Already have stress tests, but could grab popular real ones.

### Validation tools

- **naga** (already available): `naga --validate input.wgsl` — validates WGSL syntax and semantics
- **tint** (if available): SPIR-V-Tools/WebGPU validator — stricter validation
- **wgpu** runtime: Actually load the WGSL shader in a wgpu context (heavier, but definitive)

### Success criteria

- All wgpu example shaders produce naga-valid WGSL (or categorized failures with known root causes)
- Bevy shaders: at least 80% pass naga validation
- CTS: establish baseline, track improvement over time

### Categorization of failures

When a shader fails validation, categorize the failure:
- **Frontend gap**: glslpp can't parse the GLSL (e.g., unsupported extension)
- **SPIR-V gap**: glslpp can't generate valid SPIR-V for a construct
- **WGSL backend gap**: SPIR-V is valid but WGSL output has errors (our primary target)
- **Known limitation**: Feature glslpp intentionally doesn't support (e.g., OpSwitch complex cases)

### Files
- `tools/realworld_wgsl_test.zig` — new test runner (~300 lines)
- `build.zig` — add `test-realworld` step
- `tests/external/` — directory for fetched/cached shader collections (gitignored)

---

## Workstream 6: WGSL Output Quality Improvements

**Problem:** WGSL output works but has cosmetic/quality issues:
- Unnecessary local variable copies from uniform loads
- No indentation for loop/if bodies (recently added, verify quality)
- All `var` declarations even when `let` would be more idiomatic
- Missing `const` declarations for compile-time values

### 6a: Use `let` for non-mutable variables

Variables that are assigned once and never modified should use `let` instead of `var`. This is more idiomatic WGSL and may help downstream tools.

### 6b: Use `const` for literal/compile-time values

Variables initialized with compile-time-known values (literal constants, simple expressions of constants) should use `const`.

### 6c: Indentation quality

Verify that loop bodies, if/else bodies, and nested structures have proper indentation. This was recently added — verify it's working well.

### 6d: Remove unnecessary variable copies

Currently `OpLoad` always creates a `var` declaration. If the value is only read once, inline it directly:
```wgsl
// Before (current):
var _5: vec4f;
_5 = uniforms.color;
return _5;

// After (improved):
return uniforms.color;
```

### Files
- `src/spirv_to_wgsl.zig` — all quality improvements

---

## Execution Order

The workstreams are ordered by user impact:

1. **Workstream 1: README** (1-2 hours) — Highest impact, fastest to complete
2. **Workstream 3: CLI tool** (2-4 hours) — Unblocks non-Zig users
3. **Workstream 2: API cleanup** (2-3 hours) — Doc comments + visibility, small but important
4. **Workstream 4: Error handling** (2-3 hours) — Improves debugging experience
5. **Workstream 5: Real-world testing** (4-8 hours) — Validates correctness claims
6. **Workstream 6: WGSL quality** (2-4 hours) — Polish, lowest priority

Workstreams 1-3 can be done in any order. Workstream 5 should come before 6 (testing before polishing). Workstream 4 is independent.

---

## Out of Scope

These were mentioned but are explicitly deferred:

- **CopyMemoryOpt re-enablement** — Failed twice before, risky, minimal gain. Not worth the debugging time.
- **OpSwitch full support** — Already partially implemented. Remaining cases (complex fall-through) are rare in real shaders.
- **New shader stage support** (mesh, task, ray tracing) — Limited real-world demand, WGSL doesn't support these.
- **Performance optimization** — Already at ~3.6ms per shader, sufficient for interactive use.
- **Thread safety audit** — The `last_compile_detail` threadlocal is a smell but not a correctness issue in single-threaded use (the primary use case).
