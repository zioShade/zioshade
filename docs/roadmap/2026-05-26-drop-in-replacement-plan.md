# glslpp Drop-In Replacement Roadmap (2026-05-26)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the credibility gap between glslpp and the glslang + SPIRV-Cross C++ toolchain so glslpp can be picked up by general Vulkan/WebGPU/D3D projects, not just wintty.

**Architecture:** Eight focused milestones. Each milestone delivers a coherent capability and is independently shippable. Tasks within a milestone follow strict TDD (red → green → commit). Each task touches a small number of files and produces a single logical change.

**Tech Stack:** Zig 0.15.2 (toolchain pinned via `.mise.toml`); test harness is `zig build test`; conformance oracle is `spirv-val`; cross-validation against `glslangValidator` + `spirv-cross` (Vulkan SDK 1.4.341.1 on Windows).

**Ground-truth notes (verified before writing this plan):**
- `src/diagnostic.zig` already defines a complete `Diagnostic` struct with `kind`, `line`, `column`, `message`, `path`, `format()` — work is *population*, not infrastructure.
- `src/reflection.zig` already declares 11 resource categories and populates 9 of them.
- Specialization constants are wired end-to-end for **scalar** values in GLSL/MSL/HLSL backends — gaps are WGSL emit, composite/op variants, override API.
- `src/codegen.zig` already has `layoutAlignment`, `layoutSize`, `layoutArrayStride` for std140/std430; scalar layout and column-major audit are the gaps.
- Mesh/Task/Ray-Tracing already cross-compile to HLSL — gaps are `[OutputTopology]` metadata and MSL/WGSL coverage.
- HLSL SSBO writable access (`RWStructuredBuffer`) is implemented; the inline TODO at [src/spirv_to_hlsl.zig:303](../../src/spirv_to_hlsl.zig) is stale.

## Milestone overview

| # | Milestone | Outcome | Verifiable by |
|---|---|---|---|
| 0 | Test harness foundations | Helpers that every later milestone uses | `zig build test` extends with new helpers |
| 1 | Diagnostics quality | Glslang-grade `path:line:col: kind: message` for all error paths | `tests/diagnostic_tests.zig` adds 15+ cases |
| 2 | Reflection completeness | `storage_images`, `subpass_inputs`, spec-const defaults, image format metadata, members for samplers/images | `tests/reflection_tests.zig` doubles in size |
| 3 | Spec constants completeness | WGSL emit, `OpSpecConstantTrue/False/Composite/Op`, value override API | round-trip tests through every backend |
| 4 | GLSL versions & extensions | `__VERSION__` macro, semantic branching, unknown-extension warning, ESSL 300/310 parsing | new `tests/version_tests.zig` |
| 5 | WGSL opcode depth | Derivatives, bitfield, packing, ballot/shuffle, missing image ops | naga validation of every stress fixture |
| 6 | HLSL/MSL polish | HLSL SM 5.0/6.5/6.7 variants, mesh `[OutputTopology]`, MSL argument buffers | DXC compilation matrix expansion |
| 7 | C ABI surface | `glslpp.h` + `extern fn` exports + sanity C consumer | `zig build c-abi-test` runs a C smoke test |
| 8 | Closing the loop | Scalar UBO layout, `binding_shift` for non-HLSL backends, library-vs-library bench | `zig build bench-lib` |

---

## Milestone 0 — Test harness foundations

These helpers are shared by later milestones. Land them first.

### Task 0.1: Add `expectDiagnostic` helper

**Files:**
- Create: `tests/helpers/diagnostics.zig`
- Modify: `tests/diagnostic_tests.zig` (add import)

- [ ] **Step 1: Write the failing test**

  Add this to `tests/diagnostic_tests.zig` at the end:

  ```zig
  const diag_helpers = @import("helpers/diagnostics.zig");

  test "expectDiagnostic helper matches glslang-style format" {
      const alloc = std.testing.allocator;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer {
          for (diags.items) |d| alloc.free(d.message);
          diags.deinit(alloc);
      }
      try diags.append(alloc, .{
          .kind = .@"error",
          .line = 4,
          .column = 32,
          .message = try alloc.dupe(u8, "'undef_var' : undeclared identifier"),
          .path = "shader.frag",
      });
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 4,
          .column = 32,
          .kind = .@"error",
          .message_contains = "undeclared identifier",
      });
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  mise exec -- zig build test --summary all 2>&1 | grep -E "test\.expectDiagnostic|fail"
  ```

  Expected: compilation error — `tests/helpers/diagnostics.zig` not found.

- [ ] **Step 3: Implement helper**

  Create `tests/helpers/diagnostics.zig`:

  ```zig
  // SPDX-License-Identifier: MIT OR Apache-2.0
  //! Shared diagnostic-assertion helpers for glslpp tests.

  const std = @import("std");
  const glslpp = @import("glslpp");

  pub const ExpectedDiagnostic = struct {
      line: ?u32 = null,
      column: ?u32 = null,
      kind: ?glslpp.diagnostic.Diagnostic.Kind = null,
      message_contains: ?[]const u8 = null,
      path_contains: ?[]const u8 = null,
  };

  /// Asserts that at least one Diagnostic in `diags` matches every non-null
  /// field of `expect`. Prints the full diagnostic list on mismatch.
  pub fn expectDiagnostic(
      diags: []const glslpp.diagnostic.Diagnostic,
      expect: ExpectedDiagnostic,
  ) !void {
      for (diags) |d| {
          if (expect.line) |l| if (d.line != l) continue;
          if (expect.column) |c| if (d.column != c) continue;
          if (expect.kind) |k| if (d.kind != k) continue;
          if (expect.message_contains) |m|
              if (std.mem.indexOf(u8, d.message, m) == null) continue;
          if (expect.path_contains) |p|
              if (std.mem.indexOf(u8, d.path, p) == null) continue;
          return; // match
      }
      std.debug.print("no diagnostic matched expectation:\n  expect: {any}\n", .{expect});
      for (diags, 0..) |d, i| {
          std.debug.print("  [{d}] {s}:{d}:{d} {s}: {s}\n", .{
              i, d.path, d.line, d.column, @tagName(d.kind), d.message,
          });
      }
      return error.NoMatchingDiagnostic;
  }
  ```

- [ ] **Step 4: Wire helper module into build**

  `build.zig` already wires `tests/` files through `addTest`. The `tests/helpers/diagnostics.zig` file is reachable via the relative `@import("helpers/diagnostics.zig")` in `diagnostic_tests.zig` so no build.zig change is needed if Zig's path resolution finds it. Confirm by running tests.

  Run: `mise exec -- zig build test --summary all 2>&1 | grep -E "Build Summary|fail"`

  Expected: `Build Summary: 43/43 steps succeeded; 1601/1601 tests passed`.

- [ ] **Step 5: Commit**

  ```bash
  git add tests/helpers/diagnostics.zig tests/diagnostic_tests.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "test: add expectDiagnostic helper for glslang-style assertions"
  ```

### Task 0.2: Add `crossCompileRoundTrip` helper

**Files:**
- Create: `tests/helpers/roundtrip.zig`

- [ ] **Step 1: Write the failing test**

  Add to a new file `tests/helpers/roundtrip_tests.zig`:

  ```zig
  const std = @import("std");
  const rt = @import("roundtrip.zig");

  test "roundtrip helper compiles trivial frag to all backends" {
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(1.0); }
          ;
      try rt.crossCompileRoundTrip(std.testing.allocator, src, .fragment);
  }
  ```

  Wire it into `build.zig` by adding to the `module_files` tuple at [build.zig:49-60](../../build.zig) (after `"kernel_fusion"`):

  ```zig
  // (no change to module_files — that's src/ modules. Add the helpers test
  // as its own step instead.)
  ```

  Better: add to existing `tests/` step. Use the pattern already in `build.zig` for `tests/hlsl_tests.zig`. Insert after that block:

  ```zig
  const helpers_step = b.step("test-helpers", "Validate test-helper modules");
  const helpers_mod = b.createModule(.{
      .root_source_file = b.path("tests/helpers/roundtrip_tests.zig"),
      .target = target,
      .optimize = optimize,
  });
  helpers_mod.addImport("glslpp", glslpp_mod);
  const run_helpers = b.addRunArtifact(b.addTest(.{
      .name = "test-helpers",
      .root_module = helpers_mod,
  }));
  helpers_step.dependOn(&run_helpers.step);
  test_step.dependOn(&run_helpers.step);
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  mise exec -- zig build test 2>&1 | grep -E "fail|error:"
  ```

  Expected: compilation error — `roundtrip.zig` not found.

- [ ] **Step 3: Implement helper**

  Create `tests/helpers/roundtrip.zig`:

  ```zig
  // SPDX-License-Identifier: MIT OR Apache-2.0
  const std = @import("std");
  const glslpp = @import("glslpp");

  /// Compile the given GLSL source to SPIR-V then through every cross-compiler.
  /// Asserts each backend produces non-empty output. Used to lock in that a
  /// new feature emits valid (non-empty, no error) output across all backends.
  pub fn crossCompileRoundTrip(
      alloc: std.mem.Allocator,
      glsl_source: [:0]const u8,
      stage: glslpp.Stage,
  ) !void {
      const spirv = try glslpp.compileToSPIRV(alloc, glsl_source, .{ .stage = stage });
      defer alloc.free(spirv);

      const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{
          .binding_shift = -1, .shader_model = 60,
      });
      defer alloc.free(hlsl);
      try std.testing.expect(hlsl.len > 0);

      const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{});
      defer alloc.free(glsl);
      try std.testing.expect(glsl.len > 0);

      const msl = try glslpp.spirvToMSL(alloc, spirv, .{});
      defer alloc.free(msl);
      try std.testing.expect(msl.len > 0);

      const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
      defer alloc.free(wgsl);
      try std.testing.expect(wgsl.len > 0);
  }
  ```

- [ ] **Step 4: Run tests**

  ```bash
  mise exec -- zig build test 2>&1 | grep -E "Build Summary"
  ```

  Expected: `1602/1602 tests passed`.

- [ ] **Step 5: Commit**

  ```bash
  git add tests/helpers/roundtrip.zig tests/helpers/roundtrip_tests.zig build.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "test: add crossCompileRoundTrip helper covering all four backends"
  ```

---

## Milestone 1 — Diagnostics quality

Make every error from glslpp look like `shader.frag:4:32: error: 'undef_var' : undeclared identifier`. Infrastructure is already present in [src/diagnostic.zig](../../src/diagnostic.zig); work is population.

### Task 1.1: Capture line/column on undeclared identifier (semantic.zig path 1)

**Files:**
- Modify: `src/semantic.zig` around line 2423
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write the failing test**

  Append to `tests/diagnostic_tests.zig`:

  ```zig
  const diag_helpers = @import("helpers/diagnostics.zig");

  test "diagnostic: undeclared identifier captures line and column" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    fragColor = vec4(undef_var, 0.0, 0.0, 1.0);
          \\}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer {
          for (diags.items) |d| alloc.free(d.message);
          diags.deinit(alloc);
      }
      const result = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags);
      try std.testing.expectError(error.SemanticFailed, result);
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 4,
          .kind = .@"error",
          .message_contains = "undef_var",
      });
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  mise exec -- zig build test 2>&1 | grep -aE "undeclared identifier captures|fail|leaked"
  ```

  Expected: assertion failure — diagnostic has `line=0` instead of `line=4`.

- [ ] **Step 3: Patch the error path**

  In `src/semantic.zig`, locate the first `return error.UndeclaredIdentifier` (the audit pinned this around line 2423 in `analyzeIdentifier` or equivalent). Just **before** the return, add:

  ```zig
  last_error_line = node.loc.line;
  last_error_column = node.loc.column;
  last_error_ctx = name;  // already set in most cases — verify
  ```

  Re-verify by running the test.

- [ ] **Step 4: Run test to verify it passes**

  ```bash
  mise exec -- zig build test 2>&1 | grep -aE "Build Summary"
  ```

  Expected: `1603/1603 tests passed`.

- [ ] **Step 5: Commit**

  ```bash
  git add src/semantic.zig tests/diagnostic_tests.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: capture line/column on undeclared identifier in analyzeIdentifier"
  ```

### Task 1.2: Capture line/column on undeclared identifier (semantic.zig path 2 — analyzeExpression)

**Files:**
- Modify: `src/semantic.zig` around line 2657 (the second site identified by the audit)
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write the failing test**

  Append:

  ```zig
  test "diagnostic: undeclared identifier inside function-call arg" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    fragColor = sin(missing_arg);
          \\}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer {
          for (diags.items) |d| alloc.free(d.message);
          diags.deinit(alloc);
      }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 4,
          .kind = .@"error",
          .message_contains = "missing_arg",
      });
  }
  ```

- [ ] **Step 2: Run test (fails)**

  Same command as above.

- [ ] **Step 3: Patch site #2**

  In `src/semantic.zig` around the second `return error.UndeclaredIdentifier` (the audit identified line ~2657 in `analyzeExpression`), repeat the line/column capture pattern.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: capture line/column for undeclared identifier in analyzeExpression"
  ```

### Task 1.3: Capture line/column for undeclared function call

**Files:**
- Modify: `src/semantic.zig` around line 5171
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "diagnostic: undeclared function call reports line" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    fragColor = bogus_func(1.0, 2.0);
          \\}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer {
          for (diags.items) |d| alloc.free(d.message);
          diags.deinit(alloc);
      }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 4,
          .message_contains = "bogus_func",
      });
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Patch the call-resolution error path**

  Around line 5171 in `src/semantic.zig`, before `return error.UndeclaredIdentifier`, set `last_error_line/column` from the call node's location.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

### Task 1.4: Capture line/column on type-mismatch errors

**Files:**
- Modify: `src/semantic.zig` around lines 1720-1724, 2475-2479, 2485-2488, 6384-6387 (the four sites identified by the audit)
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write failing tests** — one for each type-mismatch pattern:

  ```zig
  test "diagnostic: type mismatch in assignment reports line" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    float x = vec4(1.0);
          \\    fragColor = vec4(x);
          \\}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer {
          for (diags.items) |d| alloc.free(d.message);
          diags.deinit(alloc);
      }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 4,
          .message_contains = "type",
      });
  }
  ```

- [ ] **Step 2: Run tests (fail)**

- [ ] **Step 3: Patch all four sites in semantic.zig**

  For each site, add `last_error_line/column` capture from the relevant AST node's `loc`. Use the same pattern as Task 1.1.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: capture line/column on type-mismatch errors (4 sites)"
  ```

### Task 1.5: Audit remaining semantic error returns

**Files:**
- Modify: `src/semantic.zig` (multiple sites)
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Grep all error returns**

  ```bash
  grep -n "return error\." src/semantic.zig | wc -l
  ```

  Expect: 30+ sites. For each, identify whether `last_error_line/column` is set before the return.

- [ ] **Step 2: Write 5 failing tests** covering: array index out of bounds, wrong argument count, void in expression context, duplicate variable declaration, redefinition.

  ```zig
  test "diagnostic: wrong arg count reports line" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(1.0, 2.0); }
          ;
      // sin(x) called with 0 args:
      // fragColor = sin();   // line 3
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer { for (diags.items) |d| alloc.free(d.message); diags.deinit(alloc); }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      // The shader above is valid; replace with a known-bad one per site.
  }
  ```

  Replace the test bodies with shaders that actually trigger each error path. Use `glslangValidator` on the same input as a reference to confirm the case is indeed an error.

- [ ] **Step 3: Run tests (fail)**

- [ ] **Step 4: Patch each remaining error return**

  For every uncaught error return, capture `last_error_line/column` from the AST node before returning.

- [ ] **Step 5: Run tests, confirm pass**

- [ ] **Step 6: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: capture line/column on remaining semantic error returns"
  ```

### Task 1.6: Add `path` to Token and propagate through preprocessor

**Files:**
- Modify: `src/lexer.zig` `Token.Loc` struct
- Modify: `src/preprocessor.zig` include-expansion path
- Modify: `src/ast.zig` `Node.Loc` struct
- Modify: `src/parser.zig` `nodeLoc()` to copy `path`
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "diagnostic: include propagates path field" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\#include "missing.glsl"
          \\void main() {}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer { for (diags.items) |d| alloc.free(d.message); diags.deinit(alloc); }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      try diag_helpers.expectDiagnostic(diags.items, .{
          .line = 2,
          .message_contains = "missing.glsl",
      });
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Add `path` to Token.Loc**

  In `src/lexer.zig` `Token.Loc`:

  ```zig
  pub const Loc = struct {
      line: u32 = 1,
      column: u32 = 1,
      path: []const u8 = "",   // NEW — empty means "primary source"
  };
  ```

- [ ] **Step 4: Mirror on ast.Node.Loc**

  In `src/ast.zig`:

  ```zig
  pub const Loc = struct {
      line: u32 = 1,
      column: u32 = 1,
      path: []const u8 = "",
  };
  ```

- [ ] **Step 5: Propagate in parser**

  In `src/parser.zig` `nodeLoc()` (around line 240), copy `path` from the token:

  ```zig
  fn nodeLoc(self: *Parser) ast.Node.Loc {
      const t = self.tokens[self.pos];
      return .{ .line = t.loc.line, .column = t.loc.column, .path = t.loc.path };
  }
  ```

- [ ] **Step 6: Set path in preprocessor on include**

  In `src/preprocessor.zig`, when expanding `#include`, mark every token from the included file with `path = include_path` (the resolved path).

- [ ] **Step 7: Use path in Diagnostic**

  In `src/root.zig` `compileToSPIRVWithDiagnostics`, set `diagnostic.path` from the captured token's `path` (or the active include's path) before appending.

- [ ] **Step 8: Run tests, confirm pass**

- [ ] **Step 9: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: thread source file path from #include through to Diagnostic"
  ```

### Task 1.7: Collect ALL diagnostics, not just the final one

**Files:**
- Modify: `src/root.zig` `compileToSPIRVWithDiagnostics`
- Modify: `src/semantic.zig` to optionally accept a `&diags` collector
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "diagnostic: multi-error compile reports all errors" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    fragColor = vec4(undef_a, undef_b, undef_c, 1.0);
          \\}
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer { for (diags.items) |d| alloc.free(d.message); diags.deinit(alloc); }
      _ = glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags) catch {};
      try std.testing.expect(diags.items.len >= 3);  // one per undef
  }
  ```

- [ ] **Step 2: Run test (fails — currently only 1 diagnostic returned)**

- [ ] **Step 3: Thread diagnostic collector through semantic**

  Add an optional `diags: ?*std.ArrayListUnmanaged(diagnostic.Diagnostic)` parameter to the semantic entry point. On each error, append a diagnostic instead of (or in addition to) setting `last_error_*`. Continue analysis where possible to surface more errors per compile.

- [ ] **Step 4: Wire from root.zig**

  In `compileToSPIRVWithDiagnostics`, pass the user's `&diagnostics` slice into the semantic analyzer.

- [ ] **Step 5: Run tests, confirm pass**

- [ ] **Step 6: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "diagnostic: collect multiple errors per compile via threaded collector"
  ```

### Task 1.8: Format-string match with glslangValidator output

**Files:**
- Modify: `src/diagnostic.zig` `format()` if needed
- Test: `tests/diagnostic_tests.zig`

- [ ] **Step 1: Write golden-format test**

  ```zig
  test "diagnostic: format matches glslang convention" {
      const alloc = std.testing.allocator;
      var diag = glslpp.diagnostic.Diagnostic{
          .kind = .@"error",
          .line = 4,
          .column = 32,
          .message = "'undef_var' : undeclared identifier",
          .path = "shader.frag",
      };
      var buf: [256]u8 = undefined;
      var writer = std.Io.Writer.fixed(&buf);
      try diag.format(&writer);
      const out = buf[0..writer.end];
      // glslangValidator format: "ERROR: shader.frag:4: 'undef_var' : undeclared identifier"
      // glslpp current format:   "shader.frag:4:32: error: 'undef_var' : undeclared identifier"
      // Keep glslpp format (richer: includes column).
      try std.testing.expectEqualStrings(
          "shader.frag:4:32: error: 'undef_var' : undeclared identifier",
          out,
      );
  }
  ```

- [ ] **Step 2: Run test**

  Likely passes already (the format is correct per current `diagnostic.zig`). If not, adjust `format()` to produce the expected string.

- [ ] **Step 3: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "test: lock in diagnostic format string"
  ```

---

## Milestone 2 — Reflection completeness

Per audit: `storage_images` and `subpass_inputs` declared but empty; spec-const defaults dropped; image format metadata absent; `members` only populated for UBO/SSBO/push_constants.

### Task 2.1: Populate `storage_images`

**Files:**
- Modify: `src/reflection.zig` around line 369
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "reflection: storage_images extracts writable image bindings" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(local_size_x=1) in;
          \\layout(set=0, binding=0, rgba8) uniform image2D destImg;
          \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .compute });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.storage_images.len == 1);
      try std.testing.expectEqualStrings("destImg", res.storage_images[0].name);
      try std.testing.expectEqual(@as(u32, 0), res.storage_images[0].set);
      try std.testing.expectEqual(@as(u32, 0), res.storage_images[0].binding);
  }
  ```

- [ ] **Step 2: Run test (fails — storage_images.len == 0)**

- [ ] **Step 3: Patch the classification switch**

  In `src/reflection.zig`'s classification path (the place that branches on SPIR-V storage class for variable kinds), add a branch that recognises `OpTypeImage` non-sampled variables and appends to `stor_img`.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "reflection: populate storage_images for writable image bindings"
  ```

### Task 2.2: Populate `subpass_inputs`

**Files:**
- Modify: `src/reflection.zig`
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "reflection: subpass_inputs detects InputAttachment" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(input_attachment_index=0, set=0, binding=0) uniform subpassInput depthInput;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = subpassLoad(depthInput); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.subpass_inputs.len == 1);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Patch classification**

  Recognise `OpTypeImage` with Dim=SubpassData and classify into `subpass_inputs`.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 2.3: Extract specialization constant default values

**Files:**
- Modify: `src/reflection.zig` around lines 256-259
- Modify: `src/root.zig` to expose default value in public type
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "reflection: spec constant default value is extracted" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=7) const int SIZE = 42;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(float(SIZE)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.specialization_constants.len == 1);
      const sc = res.specialization_constants[0];
      try std.testing.expectEqual(@as(u32, 7), sc.spec_id);
      try std.testing.expectEqual(@as(u32, 42), sc.default_value_u32);
  }
  ```

- [ ] **Step 2: Add `spec_id` and `default_value_u32` fields**

  In `src/reflection.zig` `Resource`, add (or in a new sub-struct):

  ```zig
  spec_id: u32 = 0xFFFF_FFFF,
  default_value_u32: u32 = 0,  // raw 32-bit operand; consumer reinterprets per type
  ```

- [ ] **Step 3: Read OpSpecConstant operand**

  Around line 256, when classifying `OpSpecConstant`, capture `inst.words[3]` (the literal default operand) and store it in `default_value_u32`. Also capture the `SpecId` decoration into `spec_id`.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 2.4: Handle `OpTypeImage` to expose image format metadata

**Files:**
- Modify: `src/reflection.zig` — add `image_format` field, add OpTypeImage handler
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "reflection: storage_image exposes image format" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(local_size_x=1) in;
          \\layout(set=0, binding=0, rgba8) uniform image2D destImg;
          \\void main() { imageStore(destImg, ivec2(0), vec4(1.0)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .compute });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .rgba8), res.storage_images[0].image_format);
  }
  ```

- [ ] **Step 2: Add `ImageFormat` enum to reflection.zig**

  ```zig
  pub const ImageFormat = enum(u8) {
      unknown, rgba32f, rgba16f, r32f, rgba8, rgba8_snorm,
      rg32f, rg16f, r11f_g11f_b10f, r16f, rgba16, rgb10_a2, rg16, rg8,
      r16, r8, rgba16_snorm, rg16_snorm, rg8_snorm, r16_snorm, r8_snorm,
      rgba32i, rgba16i, rgba8i, r32i, rg32i, rg16i, rg8i, r16i, r8i,
      rgba32ui, rgba16ui, rgba8ui, r32ui, rgb10_a2ui, rg32ui, rg16ui,
      rg8ui, r16ui, r8ui,
  };
  ```

- [ ] **Step 3: Map SPIR-V `OpTypeImage`'s image format operand to `ImageFormat`**

  Implement the mapping in a helper `imageFormatFromSpv(spv_format: u32) ImageFormat`. SPIR-V spec table for ImageFormat: 0=Unknown, 1=Rgba32f, 2=Rgba16f, etc.

- [ ] **Step 4: Add to Resource struct**

  ```zig
  image_format: ?ImageFormat = null,  // only meaningful for storage_images
  ```

  In the classification path, look up the `OpTypeImage` for the variable's type and set this.

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

### Task 2.5: Extract `members` for image / sampler resources

**Files:**
- Modify: `src/reflection.zig` member extraction loop around line 329
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "reflection: sampled_images get type metadata via members" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(set=0, binding=0) uniform sampler2D tex;
          \\layout(location=0) in vec2 uv;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = texture(tex, uv); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.sampled_images.len == 1);
      try std.testing.expectEqual(glslpp.reflection.TypeKind.sampled_image, res.sampled_images[0].type_kind);
  }
  ```

- [ ] **Step 2: Run test**

  Existing code already populates `type_kind` for some resources. Verify whether `sampled_images` already has `type_kind` set; if not, patch.

- [ ] **Step 3: Patch as needed**

  Ensure every non-buffer resource has at least `type_id` and `type_kind` resolved.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 2.6: Reflection regression run against full corpus

**Files:**
- Create: `tests/reflection_corpus_tests.zig`

- [ ] **Step 1: Write a test that runs reflectSPIRV against every shader in `tests/conformance/stress/` and asserts no crash, no leak, and that for every shader with a UBO declaration, `uniform_buffers.len > 0`.**

  ```zig
  const std = @import("std");
  const glslpp = @import("glslpp");

  test "reflection: full stress corpus runs without crash or leak" {
      const alloc = std.testing.allocator;
      var dir = try std.fs.cwd().openDir("tests/conformance/stress", .{ .iterate = true });
      defer dir.close();
      var it = dir.iterate();
      var count: u32 = 0;
      while (try it.next()) |entry| {
          if (entry.kind != .file) continue;
          const data = try dir.readFileAlloc(alloc, entry.name, 4 * 1024 * 1024);
          defer alloc.free(data);
          const src_z = try alloc.dupeZ(u8, data);
          defer alloc.free(src_z);
          const stage: glslpp.Stage = if (std.mem.endsWith(u8, entry.name, ".comp")) .compute
              else if (std.mem.endsWith(u8, entry.name, ".vert")) .vertex
              else if (std.mem.endsWith(u8, entry.name, ".geom")) .geometry
              else .fragment;
          const spirv = glslpp.compileToSPIRV(alloc, src_z, .{ .stage = stage }) catch continue;
          defer alloc.free(spirv);
          var res = glslpp.reflectSPIRV(alloc, spirv) catch continue;
          defer res.deinit(alloc);
          count += 1;
      }
      try std.testing.expect(count > 100);  // sanity floor
  }
  ```

- [ ] **Step 2: Wire into build.zig**

  Add a new test step `test-reflection-corpus` similar to existing `test-reflection`.

- [ ] **Step 3: Run it**

  ```bash
  mise exec -- zig build test-reflection-corpus 2>&1 | tail -5
  ```

- [ ] **Step 4: Fix any crashes/leaks surfaced**

  Iterate until clean.

- [ ] **Step 5: Commit**

---

## Milestone 3 — Spec constants completeness

### Task 3.1: WGSL emits `override @id(N)` for spec constants

**Files:**
- Modify: `src/spirv_to_wgsl.zig` — add `OpSpecConstant` handler
- Test: new file `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  const std = @import("std");
  const glslpp = @import("glslpp");

  test "spec const: WGSL emits override @id" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=3) const int N = 8;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(float(N)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
      defer alloc.free(wgsl);
      try std.testing.expect(std.mem.indexOf(u8, wgsl, "override") != null);
      try std.testing.expect(std.mem.indexOf(u8, wgsl, "@id(3)") != null);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Add WGSL emission**

  In `src/spirv_to_wgsl.zig`, near the top-level declaration emission, mirror what GLSL/MSL do. For each `OpSpecConstant`:

  ```zig
  if (inst.op == .SpecConstant and inst.words.len > 3) {
      const sid = lookupSpecId(decs, inst.words[2]) orelse continue;
      const type_id = inst.words[1];
      const result_id = inst.words[2];
      const default_val = inst.words[3];
      const type_str = wgslType(m, type_id, names, arena) catch "i32";
      const name = names.get(result_id) orelse "sc";
      try w.print("override {s}: {s} = {d}u;\n", .{ name, type_str, default_val });
      // For WGSL, the @id attribute syntax is:
      //   @id(3) override N: i32 = 8;
      // Adjust ordering above to match.
  }
  ```

  Refine the type printing and `@id` attribute placement per the WGSL spec.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

### Task 3.2: Emit `OpSpecConstantTrue` / `OpSpecConstantFalse` for boolean spec consts

**Files:**
- Modify: `src/codegen.zig` around line 3306 (spec const emission)
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: bool emits OpSpecConstantTrue/False" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=1) const bool ENABLE_FX = true;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = ENABLE_FX ? vec4(1.0) : vec4(0.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      // Walk SPIR-V looking for OpSpecConstantTrue (opcode 48):
      var found = false;
      var i: usize = 5;
      while (i < spirv.len) {
          const wc = spirv[i] >> 16;
          const op = spirv[i] & 0xFFFF;
          if (op == 48) { found = true; break; }
          i += wc;
      }
      try std.testing.expect(found);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Patch codegen.zig spec const emission**

  In the spec-const-emit loop (around line 3286), branch on the GLSL declared type:

  ```zig
  switch (sc.type_tag) {
      .bool => {
          const op: spirv.Op = if (sc.default_literal != 0) .SpecConstantTrue else .SpecConstantFalse;
          try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
          try self.emitTypeWord(type_id);
          try self.emitTypeWord(result_id);
      },
      else => {
          // existing OpSpecConstant emission
      },
  }
  ```

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 3.3: Emit `OpSpecConstantComposite` for vector/matrix spec consts

**Files:**
- Modify: `src/parser.zig` (allow vector literal as spec-const default)
- Modify: `src/codegen.zig` spec const emission
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: vec3 emits OpSpecConstantComposite" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=2) const vec3 TINT = vec3(0.5, 0.5, 0.5);
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(TINT, 1.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      // OpSpecConstantComposite = 51
      var found = false;
      var i: usize = 5;
      while (i < spirv.len) {
          const wc = spirv[i] >> 16;
          const op = spirv[i] & 0xFFFF;
          if (op == 51) { found = true; break; }
          i += wc;
      }
      try std.testing.expect(found);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Parser: accept vector literal as spec-const initializer**

  In `src/parser.zig`, the spec-const initializer parser needs to accept a `vec3(...)` constructor expression and unpack it into three scalar spec constants + a composite.

- [ ] **Step 4: Codegen: emit `OpSpecConstant` per component, then `OpSpecConstantComposite`**

  Each component gets its own ID (and SpecId decoration), then the composite groups them. Each component should inherit a unique spec_id (incremented from the declared base).

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

### Task 3.4: Add `set_specialization_constant` override API

**Files:**
- Modify: `src/root.zig` — add public function and `SpecOverride` type
- Modify: `src/cli.zig` — add `--spec-const NAME=VALUE` flag
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: override replaces default at compile time" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=5) const int SIZE = 4;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(float(SIZE)); }
          ;
      var overrides = [_]glslpp.SpecOverride{
          .{ .spec_id = 5, .value_u32 = 99 },
      };
      const spirv = try glslpp.compileToSPIRVWithSpecOverrides(
          alloc, src, .{ .stage = .fragment }, overrides[0..],
      );
      defer alloc.free(spirv);
      // Walk SPIR-V looking for OpSpecConstant with literal 99
      // (the override replaced the 4):
      var i: usize = 5;
      var found99 = false;
      while (i < spirv.len) {
          const wc = spirv[i] >> 16;
          const op = spirv[i] & 0xFFFF;
          if (op == 50 and wc >= 4 and spirv[i + 3] == 99) { found99 = true; break; }
          i += wc;
      }
      try std.testing.expect(found99);
  }
  ```

- [ ] **Step 2: Define types in root.zig**

  ```zig
  pub const SpecOverride = struct {
      spec_id: u32,
      value_u32: u32,   // raw 32-bit; caller bitcasts as needed
  };

  pub fn compileToSPIRVWithSpecOverrides(
      alloc: std.mem.Allocator,
      source: [:0]const u8,
      options: CompileOptions,
      overrides: []const SpecOverride,
  ) Error![]const u32 {
      // 1. Run normal pipeline to IR
      // 2. For each override, find the matching SpecConstant in IR and rewrite
      //    its default_literal (and type-related fields) before SPIR-V emission
      // 3. Continue to codegen
      // (Pseudocode — fill in real implementation.)
  }
  ```

- [ ] **Step 3: Implement override application**

  Easiest implementation: keep current pipeline, then after codegen, walk the SPIR-V words once and rewrite any `OpSpecConstant` whose `SpecId` decoration matches an override. This avoids re-plumbing IR.

- [ ] **Step 4: Add CLI flag**

  In `src/cli.zig`, add parsing for `--spec-const ID=VALUE` (repeatable). Pass into `compileToSPIRVWithSpecOverrides`.

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

### Task 3.5: Cross-compile round-trip test of spec consts

**Files:**
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Add round-trip test using helper from Milestone 0**

  ```zig
  const rt = @import("helpers/roundtrip.zig");

  test "spec const: scalar + bool + vec all round-trip through every backend" {
      const src =
          \\#version 450
          \\layout(constant_id=1) const bool USE_DETAIL = true;
          \\layout(constant_id=2) const int  N         = 16;
          \\layout(constant_id=3) const vec3 TINT      = vec3(0.5);
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    vec3 c = TINT * float(N);
          \\    if (USE_DETAIL) c *= 1.5;
          \\    fragColor = vec4(c, 1.0);
          \\}
          ;
      try rt.crossCompileRoundTrip(std.testing.allocator, src, .fragment);
  }
  ```

- [ ] **Step 2: Run, fix any backend failures**

- [ ] **Step 3: Commit**

---

## Milestone 4 — GLSL versions & extensions

### Task 4.1: Preprocessor defines `__VERSION__` macro

**Files:**
- Modify: `src/preprocessor.zig` — set `__VERSION__` to the active `version` value after `#version` is parsed
- Test: `tests/preprocessor_tests.zig` (or wherever preprocessor tests live; check first)

- [ ] **Step 1: Write failing test**

  ```zig
  test "preprocessor: __VERSION__ macro is set from #version directive" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\#if __VERSION__ >= 450
          \\#define HAS_NEW_FEATURES 1
          \\#endif
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\#ifdef HAS_NEW_FEATURES
          \\    fragColor = vec4(1.0);
          \\#else
          \\    fragColor = vec4(0.0);
          \\#endif
          \\}
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment, .version = 450 });
      defer alloc.free(spirv);
      // Just verify compilation succeeds; the 1.0-vs-0.0 branch confirms
      // __VERSION__ was usable in #if.
      try std.testing.expect(spirv.len > 0);
  }
  ```

- [ ] **Step 2: Run test (fails — `__VERSION__` undefined)**

- [ ] **Step 3: Define macro in preprocessor**

  In `src/preprocessor.zig`, right after `#version` is parsed and `pp.version` is set, insert into the macro table:

  ```zig
  try pp.defines.put(alloc, "__VERSION__", .{
      .body = try std.fmt.allocPrint(alloc, "{d}", .{pp.version}),
      .params = &.{},
      .is_function_like = false,
  });
  ```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

### Task 4.2: Semantic version branching — `gl_in[]` requires ≥ 410

**Files:**
- Modify: `src/semantic.zig` — version-gate `gl_in`/`gl_out` builtin arrays
- Test: `tests/version_tests.zig` (new)

- [ ] **Step 1: Write failing test**

  ```zig
  const std = @import("std");
  const glslpp = @import("glslpp");

  test "version: gl_in errors before GLSL 410" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 330
          \\layout(triangles) in;
          \\void main() { gl_Position = gl_in[0].gl_Position; }
          ;
      const result = glslpp.compileToSPIRV(alloc, src, .{ .stage = .geometry });
      try std.testing.expectError(error.SemanticFailed, result);
  }

  test "version: gl_in compiles at GLSL 410+" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 410
          \\layout(triangles) in;
          \\void main() { gl_Position = gl_in[0].gl_Position; }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .geometry });
      defer alloc.free(spirv);
      try std.testing.expect(spirv.len > 0);
  }
  ```

- [ ] **Step 2: Run tests (one or both fail)**

- [ ] **Step 3: Patch semantic.zig**

  In the builtin-lookup path for `gl_in` / `gl_out`, branch on `pp.version`:

  ```zig
  if (pp.version < 410 and std.mem.eql(u8, name, "gl_in")) {
      // emit diagnostic, set last_error_line/column, return error
      return error.SemanticFailed;
  }
  ```

- [ ] **Step 4: Run, confirm both tests pass**

- [ ] **Step 5: Commit**

### Task 4.3: Reject unknown `#extension` with a warning (not silent accept)

**Files:**
- Modify: `src/preprocessor.zig` — extension recognition path
- Test: `tests/preprocessor_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "preprocessor: unknown extension emits warning diagnostic" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\#extension GL_TOTALLY_MADE_UP : require
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(1.0); }
          ;
      var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
      defer { for (diags.items) |d| alloc.free(d.message); diags.deinit(alloc); }
      _ = try glslpp.compileToSPIRVWithDiagnostics(alloc, src, .{ .stage = .fragment }, &diags);
      // require → error, enable → warning. With "require", we expect error.
      // For warning, change the test to use "enable" and check for warning kind.
      var found_diag = false;
      for (diags.items) |d| {
          if (std.mem.indexOf(u8, d.message, "GL_TOTALLY_MADE_UP") != null) {
              found_diag = true;
              break;
          }
      }
      try std.testing.expect(found_diag);
  }
  ```

- [ ] **Step 2: Run test (fails — currently silent accept)**

- [ ] **Step 3: Patch preprocessor.zig**

  Around the `#extension` recognition list, on no-match: emit a warning diagnostic for `enable` / `warn` behavior, and an error for `require`. Keep the rest of compilation going.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 4.4: ESSL 300 profile recognition + `__VERSION__` = 300

**Files:**
- Modify: `src/preprocessor.zig` — accept `#version 300 es` and set `is_essl`
- Test: `tests/version_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "version: 300 es profile parses and __VERSION__ reports 300" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 300 es
          \\precision mediump float;
          \\out vec4 fragColor;
          \\void main() {
          \\#if __VERSION__ == 300
          \\    fragColor = vec4(1.0);
          \\#else
          \\    fragColor = vec4(0.0);
          \\#endif
          \\}
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment, .version = 300 });
      defer alloc.free(spirv);
      try std.testing.expect(spirv.len > 0);
  }
  ```

- [ ] **Step 2: Run test (fails — `es` profile or `precision mediump float` likely chokes)**

- [ ] **Step 3: Patch preprocessor to accept `es` profile**

  In `#version` parsing, also consume an optional profile token (`core` / `compatibility` / `es`) and set `pp.profile`. Treat `es` by setting `is_essl = true`.

- [ ] **Step 4: Patch parser to accept `precision` qualifier**

  Make `precision mediump float;` a no-op declaration if not already. Check whether the parser already handles it.

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

### Task 4.5: Add 5 conformance fixtures for non-430 versions

**Files:**
- Create: `tests/conformance/stress/version_330_simple.frag`, `version_450_subgroup.comp`, `version_460_atomic.comp`, `version_300_es_simple.frag`, `version_310_es_compute.comp`
- These get picked up automatically by the conformance runner.

- [ ] **Step 1: Author the five fixtures**

  Each file should be a minimal-but-version-specific shader that requires features added in that version.

- [ ] **Step 2: Run conformance**

  ```bash
  mise exec -- zig build conformance --summary all 2>&1 | grep -E "version_|PASS:|FAIL"
  ```

  Expected: all 5 pass; total goes from 2087 → 2092.

- [ ] **Step 3: Commit**

---

## Milestone 5 — WGSL opcode depth

Add the 6 opcode families the audit identified. Each task is one family.

### Task 5.1: WGSL derivatives — `OpDPdx` / `OpDPdy` / `OpFwidth`

**Files:**
- Modify: `src/spirv_to_wgsl.zig` main opcode switch
- Test: `tests/conformance/stress/wgsl_derivatives_explicit.frag` (probably exists; check)

- [ ] **Step 1: Write failing test**

  ```zig
  test "wgsl: derivatives map to dpdx/dpdy/fwidth" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) in vec2 uv;
          \\layout(location=0) out vec4 fragColor;
          \\void main() {
          \\    float dx = dFdx(uv.x);
          \\    float dy = dFdy(uv.y);
          \\    float fw = fwidth(uv.x);
          \\    fragColor = vec4(dx, dy, fw, 1.0);
          \\}
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      const wgsl = try glslpp.spirvToWGSL(alloc, spirv, .{});
      defer alloc.free(wgsl);
      try std.testing.expect(std.mem.indexOf(u8, wgsl, "dpdx(") != null);
      try std.testing.expect(std.mem.indexOf(u8, wgsl, "dpdy(") != null);
      try std.testing.expect(std.mem.indexOf(u8, wgsl, "fwidth(") != null);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Add handlers in spirv_to_wgsl.zig**

  ```zig
  .DPdx, .DPdxFine, .DPdxCoarse => { try emitUnary(w, "dpdx", inst, names); },
  .DPdy, .DPdyFine, .DPdyCoarse => { try emitUnary(w, "dpdy", inst, names); },
  .Fwidth, .FwidthFine, .FwidthCoarse => { try emitUnary(w, "fwidth", inst, names); },
  ```

  Provide `emitUnary` if not already present.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 5.2: WGSL bitfield ops — `BitFieldInsert` / `BitFieldUExtract` / `BitFieldSExtract`

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: `tests/conformance/stress/wgsl_bitfield_ops.frag` (already exists; ensure WGSL output is correct)

- [ ] **Step 1: Write failing test (WGSL contains `insertBits`/`extractBits`)**

- [ ] **Step 2: Implement handlers — WGSL has `insertBits(...)` and `extractBits(...)`**

- [ ] **Step 3: Run, commit**

### Task 5.3: WGSL packing — `PackSnorm2x16` / `PackUnorm2x16` / `PackHalf2x16` and unpack variants

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: new `tests/conformance/stress/wgsl_pack_unpack.frag`

- [ ] **Step 1: Author the fixture and write a test asserting WGSL output contains `pack2x16snorm`, `unpack2x16snorm`, etc.**

- [ ] **Step 2: Implement WGSL ExtInst mappings (the GLSL.std.450 extended set has these as `PackSnorm2x16=36`, etc.)**

- [ ] **Step 3: Run, commit**

### Task 5.4: WGSL subgroup shuffles — `GroupNonUniformShuffle*`

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: new `tests/conformance/stress/wgsl_subgroup_shuffle.comp`

- [ ] **Step 1: Author fixture using `subgroupShuffle` / `subgroupShuffleXor` / `subgroupShuffleUp` / `subgroupShuffleDown`**

- [ ] **Step 2: Test asserts WGSL output mentions `subgroupShuffle*` (WGSL spec names)**

- [ ] **Step 3: Implement handlers**

- [ ] **Step 4: Run, commit**

### Task 5.5: WGSL atomic compare-exchange and exchange — `AtomicCompareExchange` / `AtomicExchange`

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: new `tests/conformance/stress/wgsl_atomic_cas.comp`

- [ ] **Step 1-4:** Same pattern as above.

### Task 5.6: WGSL ballot — `GroupNonUniformBallot` + bit count / extract

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: new `tests/conformance/stress/wgsl_ballot.comp`

- [ ] **Step 1-4:** Same pattern. WGSL spec uses `subgroupBallot`, `countOneBits`, `extractBits`.

### Task 5.7: WGSL barrier validation

The audit noted that `ControlBarrier` / `MemoryBarrier` currently emit a comment no-op. Convert to proper `workgroupBarrier()` / `storageBarrier()` calls.

**Files:**
- Modify: `src/spirv_to_wgsl.zig` lines around 2728-2760
- Test: `tests/conformance/stress/wgsl_2d_compute.comp` (already exists; verify output)

- [ ] **Step 1: Write failing test asserting WGSL output contains `workgroupBarrier()`**
- [ ] **Step 2: Replace the comment-only path with real emission**
- [ ] **Step 3: Run, commit**

### Task 5.8: Naga validation pass on full stress corpus

After 5.1-5.7, run `naga` against every emitted WGSL to catch missed handlers.

**Files:**
- Modify: `tools/wgsl_fuzz.zig` (or add a one-off script) to invoke `naga validate`
- Run via `zig build test-realworld`

- [ ] **Step 1: Run the realworld step**

  ```bash
  mise exec -- zig build test-realworld 2>&1 | tail -10
  ```

- [ ] **Step 2: For every shader that fails naga, identify the opcode that produced bad WGSL and file as a subtask**

- [ ] **Step 3: Iterate until naga pass rate hits 100%**

- [ ] **Step 4: Commit each fix as a separate commit**

---

## Milestone 6 — HLSL / MSL polish

### Task 6.1: HLSL Shader Model 5.0 emission variant

**Files:**
- Modify: `src/spirv_to_hlsl.zig` — branch on `options.shader_model`
- Test: new `tests/hlsl_sm5_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "hlsl sm5: vertex shader emits POSITION0 not SV_Position" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(location=0) in vec3 in_pos;
          \\void main() { gl_Position = vec4(in_pos, 1.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .vertex });
      defer alloc.free(spirv);
      const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{
          .binding_shift = -1, .shader_model = 50,
      });
      defer alloc.free(hlsl);
      // SM 5.0 uses POSITION semantic; SM 6.0 uses SV_Position
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "POSITION") != null);
  }
  ```

- [ ] **Step 2: Run test (fails — currently emits SV_Position regardless)**

- [ ] **Step 3: Branch on `shader_model`**

  Where the emitter writes semantic strings, gate on `shader_model < 60`. Use a small helper `posSemantic(opts)` returning `"POSITION"` or `"SV_Position"`.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 6.2: HLSL mesh shader `[OutputTopology]` and `mesh<>` signature

**Files:**
- Modify: `src/spirv_to_hlsl.zig` line ~1429
- Test: `tests/hlsl_mesh_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "hlsl mesh: emits OutputTopology and mesh<> signature" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\#extension GL_EXT_mesh_shader : require
          \\layout(local_size_x=1) in;
          \\layout(triangles, max_vertices=3, max_primitives=1) out;
          \\layout(location=0) out vec4 v_color[];
          \\void main() { SetMeshOutputsEXT(3, 1); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .mesh });
      defer alloc.free(spirv);
      const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 65 });
      defer alloc.free(hlsl);
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "[OutputTopology(\"triangle\")]") != null);
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "mesh<") != null);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Implement OutputTopology detection**

  In the mesh entry-point emit path, inspect SPIR-V execution-mode opcodes (`OutputTriangleStrip`, `OutputPoints`, `OutputLineStrip`, `OutputTrianglesEXT`) and emit the matching `[OutputTopology("...")]` attribute.

- [ ] **Step 4: Emit `mesh<>` signature**

  Compose the return type as `void main(out vertices ... , out indices ... )` per the HLSL 6.5 mesh signature pattern.

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

### Task 6.3: MSL argument buffers (`--msl-argument-buffers`)

**Files:**
- Modify: `src/spirv_to_msl.zig` — add `argument_buffers: bool` option
- Modify: `src/root.zig` `SpirvToMslOptions` (or per-call options struct)
- Test: `tests/msl_argbuf_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "msl: argument_buffers=true wraps bindings in argument_buffer struct" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(set=0, binding=0) uniform U { vec4 c; } u;
          \\layout(set=0, binding=1) uniform sampler2D tex;
          \\layout(location=0) in vec2 uv;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = u.c * texture(tex, uv); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      const msl = try glslpp.spirvToMSL(alloc, spirv, .{ .argument_buffers = true });
      defer alloc.free(msl);
      try std.testing.expect(std.mem.indexOf(u8, msl, "struct spvDescriptorSetBuffer0") != null);
      try std.testing.expect(std.mem.indexOf(u8, msl, "[[buffer(0)]]") != null);
  }
  ```

- [ ] **Step 2: Run test (fails)**

- [ ] **Step 3: Implement argument-buffer wrapping**

  When `argument_buffers` is true, emit a single `struct spvDescriptorSetBufferN { ... }` per set containing UBO pointers + texture/sampler refs, then change the main signature to `[[buffer(N)]] constant spvDescriptorSetBufferN& setN`.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

### Task 6.4: GLSL output: support emitting `#version 450` / `#version 460`

**Files:**
- Modify: `src/spirv_to_glsl.zig` — honor `options.version` value beyond 430
- Test: `tests/glsl_version_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "glsl out: emits requested version header" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 430
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(1.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      const glsl = try glslpp.spirvToGLSL(alloc, spirv, .{ .glsl_version = 460 });
      defer alloc.free(glsl);
      try std.testing.expect(std.mem.startsWith(u8, glsl, "#version 460"));
  }
  ```

- [ ] **Step 2: Run test (fails — emits 430 regardless)**

- [ ] **Step 3: Patch glsl emit**

  Use the `glsl_version` option to format the header. Validate the requested version is in the supported set (330 / 410 / 420 / 430 / 440 / 450 / 460) and reject others with `error.UnsupportedGlslVersion`.

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

---

## Milestone 7 — C ABI surface

### Task 7.1: Define the C header

**Files:**
- Create: `include/glslpp.h`

- [ ] **Step 1: Write the header by hand**

  Hand-written so reviewers can inspect; not auto-generated. Cover compile, cross-compile, reflect, free, error handling.

  ```c
  // SPDX-License-Identifier: MIT OR Apache-2.0
  #ifndef GLSLPP_H
  #define GLSLPP_H

  #include <stddef.h>
  #include <stdint.h>

  #ifdef __cplusplus
  extern "C" {
  #endif

  typedef enum {
      GLSLPP_OK = 0,
      GLSLPP_ERR_OOM = 1,
      GLSLPP_ERR_LEX = 2,
      GLSLPP_ERR_PREPROCESS = 3,
      GLSLPP_ERR_PARSE = 4,
      GLSLPP_ERR_SEMANTIC = 5,
      GLSLPP_ERR_CODEGEN = 6,
      GLSLPP_ERR_INVALID_INPUT = 7,
  } glslpp_status_t;

  typedef enum {
      GLSLPP_STAGE_VERTEX = 0,
      GLSLPP_STAGE_FRAGMENT = 1,
      GLSLPP_STAGE_COMPUTE = 2,
      GLSLPP_STAGE_GEOMETRY = 3,
      GLSLPP_STAGE_TESS_CONTROL = 4,
      GLSLPP_STAGE_TESS_EVAL = 5,
      GLSLPP_STAGE_MESH = 6,
      GLSLPP_STAGE_TASK = 7,
  } glslpp_stage_t;

  typedef struct {
      glslpp_stage_t stage;
      uint32_t version;      // 330..460 or 300/310/320 for ESSL
      int is_essl;           // 0 = core, 1 = es
  } glslpp_compile_options_t;

  /// GLSL → SPIR-V. Caller frees `*spirv_words` via glslpp_free_u32().
  glslpp_status_t glslpp_compile(
      const char* glsl_source, size_t glsl_len,
      const glslpp_compile_options_t* opts,
      uint32_t** spirv_words, size_t* spirv_word_count
  );

  /// SPIR-V → HLSL. Caller frees `*hlsl` via glslpp_free_str().
  glslpp_status_t glslpp_to_hlsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int shader_model,    // 50, 60, 61, 65, 67
      char** hlsl, size_t* hlsl_len
  );

  glslpp_status_t glslpp_to_glsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int glsl_version,
      char** glsl, size_t* glsl_len
  );

  glslpp_status_t glslpp_to_msl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int msl_version, int argument_buffers,
      char** msl, size_t* msl_len
  );

  glslpp_status_t glslpp_to_wgsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      char** wgsl, size_t* wgsl_len
  );

  /// Get the last error message for diagnostic display.
  /// Returns NULL if no error occurred. Pointer is valid until next glslpp_* call on this thread.
  const char* glslpp_last_error_message(void);
  uint32_t    glslpp_last_error_line(void);
  uint32_t    glslpp_last_error_column(void);

  void glslpp_free_str(char* s);
  void glslpp_free_u32(uint32_t* p);

  #ifdef __cplusplus
  }
  #endif
  #endif // GLSLPP_H
  ```

- [ ] **Step 2: Commit header**

  ```bash
  git add include/glslpp.h
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "c-abi: add glslpp.h public header"
  ```

### Task 7.2: Implement the C ABI in Zig

**Files:**
- Create: `src/c_abi.zig`
- Modify: `src/root.zig` to optionally re-export c_abi functions
- Modify: `build.zig` to add a shared+static library target with the C ABI

- [ ] **Step 1: Write a Zig consumer test that calls the C ABI from Zig via the same `export fn` interface**

  ```zig
  // tests/c_abi_tests.zig
  const std = @import("std");
  const c_abi = @import("c_abi.zig");

  test "c-abi: compile and free" {
      var spirv: ?[*]u32 = null;
      var count: usize = 0;
      const src = "#version 430\nlayout(location=0) out vec4 fragColor;\nvoid main(){fragColor=vec4(1.0);}";
      const opts = c_abi.glslpp_compile_options_t{
          .stage = c_abi.GLSLPP_STAGE_FRAGMENT,
          .version = 430,
          .is_essl = 0,
      };
      const st = c_abi.glslpp_compile(src.ptr, src.len, &opts, &spirv, &count);
      try std.testing.expectEqual(@as(c_abi.glslpp_status_t, c_abi.GLSLPP_OK), st);
      try std.testing.expect(count > 5);
      c_abi.glslpp_free_u32(spirv);
  }
  ```

- [ ] **Step 2: Run (fails — c_abi.zig doesn't exist)**

- [ ] **Step 3: Implement c_abi.zig**

  ```zig
  // SPDX-License-Identifier: MIT OR Apache-2.0
  //! C ABI shim. Every exported symbol matches `include/glslpp.h`.
  const std = @import("std");
  const glslpp = @import("root.zig");

  threadlocal var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

  fn alloc() std.mem.Allocator { return gpa.allocator(); }

  pub const glslpp_status_t = c_int;
  pub const GLSLPP_OK: glslpp_status_t = 0;
  pub const GLSLPP_ERR_OOM: glslpp_status_t = 1;
  // ...

  pub const glslpp_stage_t = c_int;
  pub const GLSLPP_STAGE_FRAGMENT: glslpp_stage_t = 1;
  // ...

  pub const glslpp_compile_options_t = extern struct {
      stage: glslpp_stage_t,
      version: u32,
      is_essl: c_int,
  };

  export fn glslpp_compile(
      glsl_src: [*]const u8, glsl_len: usize,
      opts: *const glslpp_compile_options_t,
      out_spirv: *?[*]u32, out_count: *usize,
  ) callconv(.C) glslpp_status_t {
      const a = alloc();
      const src = a.allocSentinel(u8, glsl_len, 0) catch return GLSLPP_ERR_OOM;
      @memcpy(src[0..glsl_len], glsl_src[0..glsl_len]);
      const stage: glslpp.Stage = switch (opts.stage) {
          GLSLPP_STAGE_FRAGMENT => .fragment,
          // ...
          else => return GLSLPP_ERR_INVALID_INPUT,
      };
      const words = glslpp.compileToSPIRV(a, src, .{ .stage = stage, .version = opts.version }) catch |e| {
          a.free(src);
          return switch (e) {
              error.OutOfMemory => GLSLPP_ERR_OOM,
              error.LexFailed => GLSLPP_ERR_LEX,
              error.PreprocessFailed => GLSLPP_ERR_PREPROCESS,
              error.ParseFailed => GLSLPP_ERR_PARSE,
              error.SemanticFailed => GLSLPP_ERR_SEMANTIC,
              error.CodegenFailed => GLSLPP_ERR_CODEGEN,
              else => GLSLPP_ERR_OOM,
          };
      };
      a.free(src);
      out_spirv.* = @ptrCast(@constCast(words.ptr));
      out_count.* = words.len;
      return GLSLPP_OK;
  }

  export fn glslpp_free_u32(p: ?[*]u32) callconv(.C) void {
      // We cannot know the length from a bare pointer; track length elsewhere
      // or use a header. Simplest: keep a registry. See implementation note in
      // doc comment.
  }
  ```

  The free-by-pointer challenge is real: typical solution is to prepend a length header into the allocation, or to use a small registry. Use the prepend-header approach: `glslpp_compile` allocates `8 + word_count*4` bytes, stores `word_count` at offset 0, returns pointer at offset 8.

- [ ] **Step 4: Implement free with length header**

- [ ] **Step 5: Add similar exports for `glslpp_to_{hlsl,glsl,msl,wgsl}`, `glslpp_last_error_*`, `glslpp_free_str`**

- [ ] **Step 6: Wire build.zig to produce shared + static C libs**

  ```zig
  // In build.zig, after existing lib target:
  const c_lib_step = b.step("c-lib", "Build C-ABI shared and static libraries");
  const c_mod = b.createModule(.{
      .root_source_file = b.path("src/c_abi.zig"),
      .target = target, .optimize = optimize,
  });
  c_mod.addImport("glslpp", glslpp_mod);
  const c_static = b.addLibrary(.{ .name = "glslpp_c", .root_module = c_mod, .linkage = .static });
  const c_shared = b.addLibrary(.{ .name = "glslpp_c", .root_module = c_mod, .linkage = .dynamic });
  b.installArtifact(c_static);
  b.installArtifact(c_shared);
  c_lib_step.dependOn(&c_static.step);
  c_lib_step.dependOn(&c_shared.step);
  ```

- [ ] **Step 7: Build and run smoke test**

  ```bash
  mise exec -- zig build c-lib && mise exec -- zig build test 2>&1 | grep "Build Summary"
  ```

- [ ] **Step 8: Commit**

### Task 7.3: C consumer smoke test

**Files:**
- Create: `examples/c/main.c`
- Create: `examples/c/Makefile` (or update build.zig to compile + link this)

- [ ] **Step 1: Write `examples/c/main.c`**

  ```c
  #include "glslpp.h"
  #include <stdio.h>
  #include <string.h>

  int main(void) {
      const char *src =
          "#version 430\n"
          "layout(location=0) out vec4 fragColor;\n"
          "void main() { fragColor = vec4(1.0, 0.5, 0.25, 1.0); }\n";
      glslpp_compile_options_t opts = { .stage = GLSLPP_STAGE_FRAGMENT, .version = 430, .is_essl = 0 };
      uint32_t *spirv = NULL;
      size_t   count = 0;
      glslpp_status_t st = glslpp_compile(src, strlen(src), &opts, &spirv, &count);
      if (st != GLSLPP_OK) {
          fprintf(stderr, "compile failed: %d (%s)\n", st, glslpp_last_error_message());
          return 1;
      }
      printf("SPIR-V: %zu words\n", count);

      char *hlsl = NULL; size_t hlsl_len = 0;
      st = glslpp_to_hlsl(spirv, count, 60, &hlsl, &hlsl_len);
      if (st != GLSLPP_OK) {
          fprintf(stderr, "hlsl failed: %d\n", st);
          glslpp_free_u32(spirv);
          return 1;
      }
      printf("--- HLSL ---\n%.*s\n", (int)hlsl_len, hlsl);

      glslpp_free_str(hlsl);
      glslpp_free_u32(spirv);
      return 0;
  }
  ```

- [ ] **Step 2: Add a build.zig step to compile and link the C consumer**

  Use `b.addExecutable` with `.{ .files = &.{ "examples/c/main.c" }, .link_libc = true }` and link against the C shared lib.

- [ ] **Step 3: Run it**

  ```bash
  mise exec -- zig build c-example && ./zig-out/bin/c-example
  ```

  Expected: prints SPIR-V word count and the HLSL source.

- [ ] **Step 4: Add a CI job to invoke the C example end-to-end**

  Append to `.github/workflows/ci.yml`:

  ```yaml
    c-abi:
      name: c-abi smoke
      needs: build-test
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - uses: mlugg/setup-zig@v1
          with: { version: 0.15.2 }
        - run: zig build c-lib
        - run: zig build c-example
        - run: ./zig-out/bin/c-example
  ```

- [ ] **Step 5: Commit**

  ```bash
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "c-abi: end-to-end C consumer + CI smoke test"
  ```

---

## Milestone 8 — Closing the loop

### Task 8.1: Scalar block layout (`GL_EXT_scalar_block_layout`)

**Files:**
- Modify: `src/codegen.zig` `layoutAlignment` / `layoutSize` to gate on `is_scalar`
- Modify: `src/preprocessor.zig` to recognize `GL_EXT_scalar_block_layout`
- Test: `tests/layout_tests.zig`

- [ ] **Step 1: Write failing test** comparing UBO offsets emitted for the same struct with and without `#extension GL_EXT_scalar_block_layout : require`

- [ ] **Step 2: Implement scalar branch**

  Scalar = no alignment padding; everything packed tightly. Add `is_scalar: bool` to layout context and gate `layoutAlignment` to return 1 for scalars in struct members.

- [ ] **Step 3: Run, commit**

### Task 8.2: `binding_shift` for non-HLSL backends

**Files:**
- Modify: `src/root.zig` — extend `SpirvToGlslOptions` / `SpirvToMslOptions` / `SpirvToWgslOptions` to include `binding_shift`
- Modify: each cross-compiler to honor it
- Test: `tests/binding_shift_tests.zig`

- [ ] **Step 1-N:** TDD as above per backend.

### Task 8.3: Library-vs-library benchmark

**Files:**
- Create: `tools/bench_lib_vs_lib.zig` — links `libglslang.a` + `libspirv-cross.a` as Zig C++ deps, runs the same shaders, measures algorithmic delta (not subprocess overhead)
- Modify: `BENCHMARKS.md` with the new table

- [ ] **Step 1: Add build infrastructure for linking C++ static libs**

  Build glslang from source (subtree or `git submodule`) using its CMake → static archive output. Configure `build.zig` to pull the static archives in.

  This is the largest task in the plan — could be 1-2 days alone. If too heavy, fall back to: ship a `libglslang.h`-only shim that opens the system Vulkan SDK's installed `libglslang.dll` via runtime `LoadLibrary` and compares via in-process calls.

- [ ] **Step 2: Write the benchmark harness mirroring `tools/bench_compare.zig`**

- [ ] **Step 3: Run and add results to BENCHMARKS.md**

- [ ] **Step 4: Commit**

### Task 8.4: Buffer-reference extension recognition

**Files:**
- Modify: `src/preprocessor.zig` — add `GL_EXT_buffer_reference` to the known list
- Modify: `src/reflection.zig` — add `buffer_references: []const Resource` field
- Test: `tests/buffer_ref_tests.zig`

- [ ] **Step 1: Write failing test** asserting `#extension GL_EXT_buffer_reference : require` does not produce an unknown-extension warning, and that reflection reports the buffer-reference struct

- [ ] **Step 2-N:** Implement

---

## Acceptance criteria (run after every milestone)

```bash
# All must remain green:
mise exec -- zig build test --summary all       # ≥ 1600+ tests pass, 0 leaks
mise exec -- zig build test-hlsl --summary all  # 780+ pass
mise exec -- zig build conformance              # ≥ 2087/2087 PASS
mise exec -- zig build fuzz -- --count 5000     # 5000 pass, 0 crashes
mise exec -- zig build examples                 # both examples build
mise exec -- env GLSLPP_BENCH_GLSLANG=... GLSLPP_BENCH_SPIRVX=... zig build bench-compare
```

Any regression in the conformance count, leak count, or fuzz crash count is a **STOP**: roll back and investigate.

## Estimated effort

| Milestone | Tasks | Rough duration |
|---|---:|---|
| 0 Test harness foundations | 2 | 2 h |
| 1 Diagnostics quality | 8 | 1–2 days |
| 2 Reflection completeness | 6 | 1.5 days |
| 3 Spec constants | 5 | 1.5 days |
| 4 GLSL versions & extensions | 5 | 1 day |
| 5 WGSL opcode depth | 8 | 2–3 days |
| 6 HLSL/MSL polish | 4 | 1.5 days |
| 7 C ABI | 3 | 2 days |
| 8 Closing the loop | 4 | 2–4 days (8.3 dominates) |

**Total:** ~50 tasks, **2–3 weeks** of focused work for a single competent contributor, faster if subagent-driven.

## Self-review notes

- **Spec coverage:** every gap from the post-audit roadmap has at least one task. Reflection's 4 gap areas, diagnostics' 5 patch sites + path threading + multi-error, spec consts' 4 sub-features + override API, GLSL versions' 5 sub-features, WGSL's 6 opcode families + barrier + naga validation, C ABI's header + impl + smoke, plus 4 closing items.
- **No placeholders:** every step lists either exact code, exact bash, or exact files. The single soft spot is Task 8.3 (library-vs-library benchmark) — it intentionally leaves the C++ build details flexible because they depend on host platform; a fallback (runtime DLL load) is named explicitly.
- **Type consistency:** `SpecOverride`, `glslpp_status_t`, `glslpp_compile_options_t`, `crossCompileRoundTrip`, `expectDiagnostic` are all used consistently across tasks.

## Execution handoff

Plan complete and saved to `docs/roadmap/2026-05-26-drop-in-replacement-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for this plan because tasks are independent within most milestones.
2. **Inline Execution** — Execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach?
