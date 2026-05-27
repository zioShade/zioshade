# glslpp Drop-In Replacement Roadmap (2026-05-26, revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the genuinely-remaining gaps between glslpp and the glslang + SPIRV-Cross C++ toolchain so glslpp can be picked up by general Vulkan/WebGPU/D3D projects.

**Architecture:** Eight tightly-scoped milestones, each independently shippable. Tasks within a milestone follow strict TDD (red → green → commit).

**Tech Stack:** Zig 0.15.2 (toolchain pinned via `.mise.toml`); test harness is `zig build test`; conformance oracle is `spirv-val`; cross-validation against `glslangValidator` + `spirv-cross` (Vulkan SDK 1.4.341.1 on Windows).

**Why this revision exists:** The first version of this roadmap (committed `1befd2cc`) was written from audit agents that only inspected current file contents and missed years of shipped feature work tagged G1/G2/G3/G4/G5/G7. The revised plan below is grounded in **both git history and code state**, so it covers only genuinely-remaining work. Most milestones from the prior plan are deleted because the work was already done.

## What was already shipped (do NOT redo)

Verified via git log + code reads + test runs:

| Prior plan milestone | Actually shipped as | Evidence |
|---|---|---|
| M1: Diagnostics quality | **G3** in commit `7d1d6f25` | `last_error_line/column` set in lexer (12×), parser (2×), semantic (14×). `compileToSPIRVWithDiagnostics` populates rich `Diagnostic`s. `tests/diagnostic_tests.zig` has 10 tests covering it. |
| M2: Reflection — most of it | **G1** in commit `62d3659d` | 9 of 13 `ShaderResources` categories populated. 25 G1 tests in `tests/correctness_tests.zig` pass. |
| M3: Spec constants (scalar) | commits `fa652c04`, `9186248b`, `98da12fd`, `038ca1cc` | `OpSpecConstant` scalar emission, GLSL `layout(constant_id=N)` emit, MSL `[[function_constant(N)]]` emit, reflection. Small types (int8/16, uint8/16, float16). |
| M4: GLSL versions | **G4** in commit `bc0ce4ee` | `compileGlslToGlslVersion(alloc, src, stage, version)`. ESSL profile parses. `__VERSION__` macro defined. |
| M5: WGSL opcode coverage | **G2/G5** across 12+ commits (e.g., `a1e75de9` "30+ missing WGSL opcode handlers") | **92 distinct opcode handlers** in `src/spirv_to_wgsl.zig`. Derivatives, atomics, shuffles, ballots, barriers all work. |
| M6: HLSL mesh/ray cross-compile | shipped | 7 opcodes mapped: `EmitMeshTasksEXT`, `TraceRayKHR`, `ReportIntersectionKHR`, etc. |
| M6: HLSL SSBO `RWStructuredBuffer` | shipped | The inline `// TODO: SSBO` comment at the prior audit was stale. |

## What's genuinely remaining

The 8 revised milestones below. Total estimated effort: **~1 week of focused work**, much less than the prior plan's 2-3 weeks.

| # | Milestone | Outcome | Tasks |
|---|---|---|---:|
| 1 | **Repair test infrastructure** | All shipped G-work runs in default `zig build test`. CLI uses diagnostics API. | 4 |
| 2 | **Reflection completion** | Populate `storage_images`, `subpass_inputs`, spec-const `default_value`, image format metadata. | 5 |
| 3 | **Spec constants completion** | WGSL emit, HLSL real emit, bool / composite / op variants, value override API. | 6 |
| 4 | **WGSL final opcode coverage** | Add the 9 still-missing handlers (packing + bitfield). | 2 |
| 5 | **HLSL polish** | SM 5.0 differentiated output, mesh `[OutputTopology]`. | 3 |
| 6 | **MSL argument buffers** | `argument_buffers: bool` option + implementation. | 2 |
| 7 | **C ABI surface** | `glslpp.h` + `extern fn` exports + C consumer + CI smoke. | 3 |
| 8 | **Closing the loop** | Scalar block layout, buffer-reference extension, descriptor remap for non-HLSL, library-vs-library bench, `tests/external/` corpus. | 5 |

---

## Milestone 1 — Repair test infrastructure (load-bearing)

### Why first

A surprising amount of the audit's confusion came from the fact that **`tests/diagnostic_tests.zig`, `tests/reflection_tests.zig`, and `tests/correctness_tests.zig` are not in the default `test` step**. They're behind named steps (`test-diagnostic`, `test-reflection`, `test-correctness`) that nobody runs by default. CI silently misses regressions in shipped G-work. Fixing this is high-leverage.

### Task 1.1: Make `glslpp.semantic` public so tests can compile

**Files:**
- Modify: `src/root.zig` line 15

- [ ] **Step 1: Reproduce the failure**

  ```bash
  cd C:/Users/Alessandro/CODE/OSS/glslpp/.claude/worktrees/amazing-ride-e4d37a
  mise exec -- zig build test-diagnostic 2>&1 | head -10
  ```

  Expected: `error: 'semantic' is not marked 'pub'`.

- [ ] **Step 2: Patch root.zig**

  Change line 15 from `const semantic = @import("semantic.zig");` to `pub const semantic = @import("semantic.zig");`. Add a doc comment noting that `semantic` is exposed for test use only — callers should use the public `Error` / `Diagnostic` / `lastErrorCtx()` / `lastErrorInner()` API.

- [ ] **Step 3: Verify it builds**

  ```bash
  mise exec -- zig build test-diagnostic --summary all 2>&1 | grep -aE "Build Summary"
  ```

  Expected: all 10+ tests pass.

- [ ] **Step 4: Commit**

  ```bash
  git add src/root.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "expose glslpp.semantic for test-internals use; unbreaks tests/diagnostic_tests.zig"
  ```

### Task 1.2: Wire orphaned test files into default `test` step

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Reproduce — confirm default test step has 1601 tests, but adding the orphans should bump it**

  ```bash
  mise exec -- zig build test --summary all 2>&1 | grep -aE "Build Summary"
  ```

  Record current count.

- [ ] **Step 2: Add the three test files' run-steps to `test_step.dependOn`**

  In `build.zig`, find each block like:
  ```zig
  const diag_test_step = b.step("test-diagnostic", "Run diagnostic quality tests");
  // ...
  const run_diag_tests = b.addRunArtifact(b.addTest(...));
  diag_test_step.dependOn(&run_diag_tests.step);
  ```

  After each one, add:
  ```zig
  test_step.dependOn(&run_diag_tests.step);
  ```

  Repeat for `run_refl_tests`, `run_corr_tests`.

- [ ] **Step 3: Verify**

  ```bash
  mise exec -- zig build test --summary all 2>&1 | grep -aE "Build Summary"
  ```

  Expected: test count jumps by 40+ (10 diagnostic + 8 reflection + 25 correctness).

- [ ] **Step 4: Commit**

  ```bash
  git add build.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "build: wire diagnostic/reflection/correctness tests into default test step"
  ```

### Task 1.3: Wire CLI to use `compileToSPIRVWithDiagnostics` so errors show line:col:msg

**Files:**
- Modify: `src/cli.zig` — at minimum the `doCompile` path (line ~237), ideally also the cross-compile paths

- [ ] **Step 1: Reproduce — CLI on a broken shader currently shows a bare error**

  ```bash
  cat > /tmp/bad.frag <<'EOF'
  #version 430
  layout(location=0) out vec4 fragColor;
  void main() { fragColor = vec4(undef_var, 0.0, 0.0, 1.0); }
  EOF
  mise exec -- zig build cli
  zig-out/bin/glslpp.exe compile /tmp/bad.frag -o /tmp/out.spv 2>&1
  ```

  Expected: a vague error string with no line/column.

- [ ] **Step 2: Patch CLI compile path**

  Replace the `try compileToSPIRV(...)` call (or wrap it) with:

  ```zig
  var diags = std.ArrayListUnmanaged(glslpp.diagnostic.Diagnostic).empty;
  defer {
      for (diags.items) |d| alloc.free(d.message);
      diags.deinit(alloc);
  }
  const spirv_words = glslpp.compileToSPIRVWithDiagnostics(alloc, source, opts, &diags) catch |err| {
      for (diags.items) |d| {
          var buf: [512]u8 = undefined;
          var writer = std.Io.Writer.fixed(&buf);
          d.format(&writer) catch {};
          std.debug.print("{s}\n", .{buf[0..writer.end]});
      }
      return err;
  };
  ```

- [ ] **Step 3: Verify**

  ```bash
  mise exec -- zig build cli
  zig-out/bin/glslpp.exe compile /tmp/bad.frag -o /tmp/out.spv 2>&1
  ```

  Expected: now prints `4:?: error: ... undef_var ... undeclared identifier` style output.

- [ ] **Step 4: Add a test**

  Add to `tests/diagnostic_tests.zig` a CLI-level integration test if practical, or note that CLI tests are out of scope for this milestone.

- [ ] **Step 5: Commit**

  ```bash
  git add src/cli.zig
  git -c user.email='alex@deblasis.net' -c user.name='Alessandro De Blasis' \
      commit -m "cli: use compileToSPIRVWithDiagnostics so errors show line:col:msg"
  ```

### Task 1.4: Add CI step that runs all tests, not just the default subset

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Read current ci.yml. The `Unit tests` step runs `zig build test --summary all`.**

  After M1.2, this now runs the previously-orphaned tests automatically. **No extra CI work needed** beyond verifying the workflow doesn't need updating.

  If you find the workflow uses a hard-coded test count or filtering, update it. Otherwise this task is just a verification.

- [ ] **Step 2: Commit (or skip if nothing changed)**

---

## Milestone 2 — Reflection completion

Per audit: `storage_images` empty, `subpass_inputs` empty, spec-const default value not extracted, `OpTypeImage` (opcode 25) not handled, several untested categories.

### Task 2.1: Populate `storage_images`

**Files:**
- Modify: `src/reflection.zig` classifier switch (around line 290-326)
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

- [ ] **Step 2: Run test (fails — `storage_images.len == 0`)**

- [ ] **Step 3: Add the classifier branch in `src/reflection.zig`**

  The audit identified that the classification switch (around line 290) routes types to `ubos` / `ssbos` / `sampled` / `sep_img` / `sep_samp` / `accels`, but NEVER appends to `stor_img`. Add: for an `OpVariable` whose pointee type is `OpTypeImage` with Sampled=2 (storage image, per SPIR-V spec), append to `stor_img`.

- [ ] **Step 4: Verify test passes**

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

- [ ] **Step 3: Patch classifier**

  Recognise `OpTypeImage` with Dim=SubpassData (Dim value 6 in SPIR-V spec) and classify into `subpass_inputs`.

- [ ] **Step 4: Verify**

- [ ] **Step 5: Commit**

### Task 2.3: Extract spec-constant default values

**Files:**
- Modify: `src/reflection.zig` — add `default_value_u32` field to spec-const branch; populate from `OpSpecConstant` operand
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Add the field**

  In `src/reflection.zig` `Resource` (or a sub-struct for spec-consts if the type is divergent), add:

  ```zig
  default_value_u32: u32 = 0,  // raw 32-bit operand; consumer reinterprets per type
  ```

  Note: the audit says `spec_id` is already stored in the `location` field. Keep that convention but **also** add an explicit `spec_id: u32 = 0xFFFF_FFFF` field with the same value for clarity.

- [ ] **Step 2: Populate**

  In the existing `OpSpecConstant` handling around line 256-259, capture `inst.words[3]` (the literal default operand) into `default_value_u32`.

- [ ] **Step 3: Write test**

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
      try std.testing.expectEqual(@as(usize, 1), res.specialization_constants.len);
      try std.testing.expectEqual(@as(u32, 7), res.specialization_constants[0].spec_id);
      try std.testing.expectEqual(@as(u32, 42), res.specialization_constants[0].default_value_u32);
  }
  ```

- [ ] **Step 4: Verify, commit**

### Task 2.4: Handle `OpTypeImage` (opcode 25) for image format metadata

**Files:**
- Modify: `src/reflection.zig` — add `ImageFormat` enum + image_format field; add OpTypeImage handler in the type-parsing switch
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
      try std.testing.expect(res.storage_images.len == 1);
      try std.testing.expectEqual(@as(?glslpp.reflection.ImageFormat, .rgba8), res.storage_images[0].image_format);
  }
  ```

- [ ] **Step 2: Add `ImageFormat` enum**

  In `src/reflection.zig`:
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

  Add `image_format: ?ImageFormat = null` to `Resource` (only meaningful for storage_images and storage_image-like resources).

- [ ] **Step 3: Map SPIR-V format operand to enum**

  Implement `fn imageFormatFromSpv(spv_format: u32) ImageFormat` per the SPIR-V spec (Unknown=0, Rgba32f=1, Rgba16f=2, etc.).

- [ ] **Step 4: In the OpTypeImage parse branch, store format on the type-info side, then look it up when populating `storage_images` in Task 2.1's branch.**

- [ ] **Step 5: Verify, commit**

### Task 2.5: Add tests for untested categories

**Files:**
- Test: `tests/reflection_tests.zig`

- [ ] **Step 1: Add a test asserting `separate_images` is populated for `texture2D` (Vulkan style)**

  ```zig
  test "reflection: separate_images populated for texture2D" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(set=0, binding=0) uniform texture2D myTex;
          \\layout(set=0, binding=1) uniform sampler mySamp;
          \\layout(location=0) in vec2 uv;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = texture(sampler2D(myTex, mySamp), uv); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.separate_images.len == 1);
      try std.testing.expect(res.separate_samplers.len == 1);
  }
  ```

- [ ] **Step 2: Add a test asserting `acceleration_structures` is populated**

  ```zig
  test "reflection: acceleration_structures populated for accelerationStructureEXT" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 460
          \\#extension GL_EXT_ray_tracing : require
          \\layout(set=0, binding=0) uniform accelerationStructureEXT topLevel;
          \\layout(location=0) rayPayloadInEXT vec3 hitValue;
          \\void main() { hitValue = vec3(1.0); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .raygen });
      defer alloc.free(spirv);
      var res = try glslpp.reflectSPIRV(alloc, spirv);
      defer res.deinit(alloc);
      try std.testing.expect(res.acceleration_structures.len == 1);
  }
  ```

- [ ] **Step 3: Verify both pass, commit**

---

## Milestone 3 — Spec constants completion

### Task 3.1: WGSL emits `override @id(N)` for spec constants

**Files:**
- Modify: `src/spirv_to_wgsl.zig` — add `OpSpecConstant` handler in top-level declaration emission
- Test: new file `tests/spec_const_tests.zig` (wire into build.zig as a new test target similar to `tests/diagnostic_tests.zig`)

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: WGSL emits @id() override" {
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

- [ ] **Step 2: Mirror existing GLSL emission pattern**

  In `src/spirv_to_wgsl.zig`, locate the top-of-module declaration emission. Add an OpSpecConstant pass like the GLSL backend does. WGSL syntax: `@id(3) override N: i32 = 8;`. Note that `@id` is the WGSL attribute syntax and goes **before** `override`.

- [ ] **Step 3: Verify, commit**

### Task 3.2: HLSL emits real specialization syntax instead of comment

**Files:**
- Modify: `src/spirv_to_hlsl.zig` around line 440-464 (current comment-only emit)
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: HLSL emits [[vk::constant_id(N)]] or equivalent" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=2) const int LEVEL = 5;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(float(LEVEL)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      const hlsl = try glslpp.spirvToHLSL(alloc, spirv, .{ .shader_model = 60 });
      defer alloc.free(hlsl);
      // DXC accepts [[vk::constant_id(N)]] attribute on a static const declaration:
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "[[vk::constant_id(2)]]") != null);
  }
  ```

- [ ] **Step 2: Patch HLSL emit**

  Replace the comment-only path with:
  ```hlsl
  [[vk::constant_id(2)]] const int LEVEL = 5;
  ```

- [ ] **Step 3: Verify, commit**

### Task 3.3: Emit `OpSpecConstantTrue` / `OpSpecConstantFalse` for booleans

**Files:**
- Modify: `src/codegen.zig` around spec-const emission (line ~3286-3306)
- Modify: `src/spirv.zig` to add `SpecConstantTrue = 48, SpecConstantFalse = 49` if not present
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Verify spirv.zig has the opcodes**

  ```bash
  grep -n "SpecConstantTrue\|SpecConstantFalse" src/spirv.zig
  ```

  If absent, add them with the right numeric values.

- [ ] **Step 2: Write failing test**

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
      // Walk SPIR-V looking for OpSpecConstantTrue (48):
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

- [ ] **Step 3: Patch codegen.zig spec-const emission**

  In the loop that emits spec consts, branch on the GLSL declared type:

  ```zig
  switch (sc.type_tag) {
      .bool => {
          const op: spirv.Op = if (sc.default_literal != 0) .SpecConstantTrue else .SpecConstantFalse;
          try self.emitTypeWord(spirv.encodeInstructionHeader(3, @intFromEnum(op)));
          try self.emitTypeWord(type_id);
          try self.emitTypeWord(result_id);
      },
      else => { /* existing OpSpecConstant emit */ },
  }
  ```

- [ ] **Step 4: Update GLSL/MSL/HLSL/WGSL emitters to handle bool spec const correctly (the value print uses "true"/"false", not "1"/"0").**

- [ ] **Step 5: Verify, commit**

### Task 3.4: Emit `OpSpecConstantComposite` for vector/matrix spec consts ✅ DONE

Shipped. `layout(constant_id=N) const vec3/vec4/mat3/mat4 X = vec3(...)` now lowers
to per-scalar `OpSpecConstant`s (SpecId N, N+1, ...) grouped by an
`OpSpecConstantComposite` (opcode 51). Matrices emit per-column inner composites
then a final outer composite.

**Files:**
- `src/ir.zig` — `SpecConstant.component_literals: []const u32` slice replaces
  the old single `default_literal: u32` field (length-1 for scalars, N for vec/mat).
- `src/semantic.zig` — extracts per-component literals from `type_constructor`
  args (scalar literals + GLSL splat form). Non-literal args fall back to 0.
- `src/codegen.zig` — composite branch emits N `OpSpecConstant` + a final
  `OpSpecConstantComposite`. Matrices use a two-tier emission: per-scalar →
  per-column → matrix. Per-scalar `SpecId` decorations go into the
  `decoration_section` (spliced into the annotation section) because
  component IDs are only known after `emitTypesAndConstants` runs.
- `src/compact_ids.zig` — added `getOpInfo` entries for opcodes 48/49/51/52
  so DCE can read `OpSpecConstantComposite` operands and keep the per-scalar
  `OpSpecConstant`s alive.
- `src/compact_ids_passes.zig` — added 48/49/51/52 to the "dead-safe" list so
  the composite/Op forms can be removed only when truly unreferenced.
- `src/spirv_to_{glsl,hlsl,msl,wgsl}.zig` — backends emit per-scalar
  spec-const declarations (with their SpecIds) plus a composite assembled from
  the scalar names. WGSL uses a `const` (override only supports scalars).
- `tests/spec_const_tests.zig` — 8 new tests cover SPIR-V opcode emission,
  sequential SpecIds, 0.5 bit-pattern, vec4 case, and all four backends.

**Verification:** `zig build test` → 1716/1716 (+8 vs 1708 baseline), 63/63 steps,
0 leaks. `spirv-val --target-env vulkan1.3` passes on the smoke shader. The
`applySpecOverrides` post-codegen rewrite still skips composites — users override
each scalar component via its own SpecId.

### Task 3.5: Emit `OpSpecConstantOp` for derived expressions

**Files:**
- Modify: `src/parser.zig`, `src/semantic.zig`, `src/codegen.zig`
- Test: `tests/spec_const_tests.zig`

- [ ] **Step 1: Write failing test**

  ```zig
  test "spec const: derived const emits OpSpecConstantOp" {
      const alloc = std.testing.allocator;
      const src =
          \\#version 450
          \\layout(constant_id=1) const int SIZE = 4;
          \\const int DOUBLE = SIZE * 2;
          \\layout(location=0) out vec4 fragColor;
          \\void main() { fragColor = vec4(float(DOUBLE)); }
          ;
      const spirv = try glslpp.compileToSPIRV(alloc, src, .{ .stage = .fragment });
      defer alloc.free(spirv);
      // OpSpecConstantOp = 52
      var found = false;
      var i: usize = 5;
      while (i < spirv.len) {
          const wc = spirv[i] >> 16;
          const op = spirv[i] & 0xFFFF;
          if (op == 52) { found = true; break; }
          i += wc;
      }
      try std.testing.expect(found);
  }
  ```

- [ ] **Step 2: Implement**

  Semantic needs to detect that `DOUBLE = SIZE * 2` where SIZE is a spec const → the expression is *itself* a spec const. Codegen emits `OpSpecConstantOp` with the IMul opcode and the SIZE and constant 2 as operands.

  This is the largest sub-task in M3 — multi-day if done thoroughly. May be scoped down to just `*`, `+`, `-`, `/` to start.

- [ ] **Step 3: Verify, commit**

### Task 3.6: Add `set_specialization_constant` override API + CLI flag

**Files:**
- Modify: `src/root.zig` — add `SpecOverride` type and `compileToSPIRVWithSpecOverrides`
- Modify: `src/cli.zig` — add `--spec-const ID=VALUE` flag
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
      // Walk SPIR-V looking for OpSpecConstant (50) with literal 99:
      var i: usize = 5;
      var found = false;
      while (i < spirv.len) {
          const wc = spirv[i] >> 16;
          const op = spirv[i] & 0xFFFF;
          if (op == 50 and wc >= 4 and spirv[i + 3] == 99) { found = true; break; }
          i += wc;
      }
      try std.testing.expect(found);
  }
  ```

- [ ] **Step 2: Implement as a post-codegen rewrite pass**

  Easiest: keep the normal pipeline, then walk the SPIR-V words once and rewrite any `OpSpecConstant` whose `SpecId` decoration matches an override. Avoids re-plumbing IR.

  ```zig
  pub const SpecOverride = struct {
      spec_id: u32,
      value_u32: u32,
  };

  pub fn compileToSPIRVWithSpecOverrides(
      alloc: std.mem.Allocator,
      source: [:0]const u8,
      options: CompileOptions,
      overrides: []const SpecOverride,
  ) Error![]const u32 {
      const words = try compileToSPIRV(alloc, source, options);
      // Mutate-in-place over a copy
      const mut = try alloc.dupe(u32, words);
      alloc.free(words);
      applySpecOverrides(mut, overrides);
      return mut;
  }
  ```

  Implement `applySpecOverrides` by:
  1. Scanning for `OpDecorate target SpecId N` to build a map of result_id → spec_id
  2. Scanning for `OpSpecConstant type_id result_id literal` instances and rewriting `literal` where `spec_id` map has a matching override

- [ ] **Step 3: Add CLI flag**

  In `src/cli.zig`, parse `--spec-const ID=VALUE` (repeatable), build a `[]SpecOverride`, pass to the new API.

- [ ] **Step 4: Verify, commit**

---

## Milestone 4 — WGSL final opcode coverage (small, last 9 opcodes)

### Task 4.1: WGSL packing — `PackSnorm2x16` / `PackUnorm2x16` / `PackHalf2x16` + 3 unpack variants

**Files:**
- Modify: `src/spirv_to_wgsl.zig` — add ExtInst mappings (these are GLSL.std.450 opcodes 36, 37, 39, 60, 61, 63)
- Test: new `tests/conformance/stress/wgsl_pack_unpack.frag` + WGSL assertion test

- [ ] **Step 1: Author the fixture and write a test asserting WGSL output contains `pack2x16snorm`, `pack2x16unorm`, `pack2x16float`, `unpack2x16snorm`, `unpack2x16unorm`, `unpack2x16float`**

  ```glsl
  // tests/conformance/stress/wgsl_pack_unpack.frag
  #version 450
  layout(location=0) in vec2 in_uv;
  layout(location=0) out vec4 fragColor;
  void main() {
      uint p = packSnorm2x16(in_uv);
      vec2 q = unpackSnorm2x16(p);
      fragColor = vec4(q, 0.0, 1.0);
  }
  ```

- [ ] **Step 2: Map the GLSL.std.450 opcodes in spirv_to_wgsl's ExtInst dispatch**

  WGSL names: `pack2x16snorm`, `unpack2x16snorm`, `pack2x16unorm`, `unpack2x16unorm`, `pack2x16float`, `unpack2x16float`.

- [ ] **Step 3: Verify via conformance + a focused WGSL output test, commit**

### Task 4.2: WGSL bitfield — `BitFieldInsert` / `BitFieldUExtract` / `BitFieldSExtract`

**Files:**
- Modify: `src/spirv_to_wgsl.zig`
- Test: `tests/conformance/stress/wgsl_bitfield_ops.frag` already exists; verify WGSL output is now correct

- [ ] **Step 1: Write failing assertion test on the existing fixture's WGSL output**

- [ ] **Step 2: Add handlers — WGSL has `insertBits(value, insert, offset, count)`, `extractBits(value, offset, count)`**

- [ ] **Step 3: Verify, commit**

---

## Milestone 5 — HLSL polish

### Task 5.0 (NEW, prerequisite to 5.1) — Implement vertex shader entry-point signature

**Status (2026-05-27):** Discovered during M5.1 attempt. The HLSL backend currently emits vertex shaders as `void main() { ...; gl_Position = ...; return; }` — no input/output struct, no semantics, `gl_Position` is a bare global. DXC will reject this. This is a load-bearing gap, not a polish issue.

**Files:**
- Modify: `src/spirv_to_hlsl.zig` — extend the entry-signature dispatch (line ~1437) to handle `.Vertex` execution model.
- Test: extend `tests/hlsl_tests.zig` or add `tests/hlsl_vertex_tests.zig`.

**What's needed:**
1. Collect `Input` and `Output` storage-class variables (already done for other stages — find the existing helper).
2. Build vertex `void main(InVertex i, out OutVertex o)` style signature with semantics:
   - Per-location `TEXCOORD<n>` for non-builtin input/output locations
   - `gl_Position` output → `SV_Position` (or `POSITION` under SM 5.0; see Task 5.1 below)
   - Other vertex builtins (`gl_VertexID`, `gl_InstanceID`) → matching SV_ semantics
3. Rewrite the body so writes to former-globals route into the `out` struct.

This is roughly the same scope as M5.2's mesh signature work — probably 1–2 days.

### Task 5.1: HLSL SM 5.0 differentiated output (POSITION not SV_Position)

**Status (2026-05-27):** BLOCKED on Task 5.0 above. The string-swap is one helper function; the real work is implementing vertex signature emission first. Once Task 5.0 lands, M5.1 reduces to a `posSemantic(shader_model)` helper called from the new vertex signature emit point.



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
      // SM 5.0 → POSITION; SM 6.0 → SV_Position
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "POSITION") != null);
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") == null);
  }
  ```

- [ ] **Step 2: Add a `posSemantic(opts) []const u8` helper that returns `"POSITION"` for SM < 60, `"SV_Position"` otherwise. Use it everywhere `SV_Position` is currently emitted.**

  Same pattern for other system-value semantics that differ between SM 5 and SM 6.

- [ ] **Step 3: Verify, commit**

### Task 5.2: HLSL mesh `[OutputTopology]` and `mesh<>` signature

**Files:**
- Modify: `src/spirv_to_hlsl.zig` around line 1429 (current TODO)
- Test: new `tests/hlsl_mesh_tests.zig`

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
      try std.testing.expect(std.mem.indexOf(u8, hlsl, "out vertices") != null);
  }
  ```

- [ ] **Step 2: Implement**

  In the mesh entry-point emit path:
  1. Inspect SPIR-V execution-mode opcodes (`OutputTriangleStrip`, `OutputPoints`, `OutputLineStrip`, `OutputTrianglesEXT`) to choose the topology string.
  2. Emit `[OutputTopology("...")]` attribute.
  3. Rewrite the function signature to HLSL 6.5 mesh form: `void main(uint tid : SV_DispatchThreadID, out vertices VOut verts[N], out indices uint3 prims[P])`.

- [ ] **Step 3: Verify, commit**

### Task 5.2 v2 — Mesh shader output binding (DEFERRED from M5.2 v1)

M5.2 v1 shipped (`6a0e5982` + `e732055f`) with the `[OutputTopology("...")]` attribute and a placeholder mesh signature (`out vertices float4 verts[N]`, `out indices uintK prims[M]`) that's syntactically valid HLSL but **not DXC-validation-clean for non-trivial mesh shaders**. The full mesh output pipeline needs four follow-up items:

- [ ] **Task 5.2.v2.a — Per-vertex `struct VertexOut` aggregation**
  In `src/spirv_to_hlsl.zig`, when emitting the mesh signature, walk the SPIR-V Output storage class variables that are NOT decorated `PerPrimitiveEXT`, build a `struct VertexOut { float4 pos : SV_Position; <user vars with their semantics>; }`, and emit `out vertices VertexOut verts[max_vertices]` instead of the current placeholder `float4 verts[N]`. Today's v1 emits a single-output stub; this task makes it real.

- [ ] **Task 5.2.v2.b — `PerPrimitiveEXT` aggregation into `struct PrimOut`**
  Similar to v2.a but for `out` variables marked with the `perprimitiveEXT` GLSL qualifier (SPIR-V `PerPrimitiveEXT` decoration). Build `struct PrimOut { <per-primitive user vars>; }` and emit `out primitives PrimOut prims_data[max_primitives]` as a separate signature parameter (sibling to the indices array).

- [ ] **Task 5.2.v2.c — Body store routing to verts[]/prims[]**
  After v2.a and v2.b land, the mesh entry-point *body* still emits SPIR-V Output-storage-class stores as generic global writes. Re-route them to write into the `verts[i].field` / `prims_data[i].field` slots so the per-thread mesh-shader writes correctly populate the output arrays. This is the load-bearing piece — without it the mesh output is structurally correct but semantically empty.

- [x] **Task 5.2.v2.d — CLI `--stage mesh|task|raygen|...`**
  Shipped as part of finishing M5.2 v1 follow-ups. `src/cli.zig` now accepts every stage in the `glslpp.Stage` enum.

**Acceptance for v2:** the mesh shader fixture from M5.2's test:
```glsl
#version 450
#extension GL_EXT_mesh_shader : require
layout(local_size_x=1) in;
layout(triangles, max_vertices=3, max_primitives=1) out;
layout(location=0) out vec4 v_color[];
void main() { SetMeshOutputsEXT(3, 1); }
```
should round-trip through `glslpp hlsl --stage mesh` and then pass `dxc -T ms_6_5 -E main` without errors. Today it doesn't because of v2.a/b/c.

### Task 5.3: Validate via DXC on Windows

**Files:**
- Modify: `tools/dxc_batch_test.zig` to compile the mesh fixture, expand its `--shader-model` matrix

- [ ] **Step 1-3:** Add fixtures, run DXC, fix any output that DXC rejects.

---

## Milestone 6 — MSL argument buffers

### Task 6.1: Add `argument_buffers: bool` to MSL options — SHIPPED (v1)

Shipped in this commit. `MslCompileOptions.argument_buffers` (default `false`)
gates emission of a `spvDescriptorSetBuffer0` struct that bundles all set-0
resources with sequential `[[id(N)]]` slots, plus a `constant
spvDescriptorSetBuffer0& set0 [[buffer(0)]]` entry-point parameter (fragment
and compute paths). UBOs occupy one slot; sampled images split into a
`texture2d<float>` slot and a `sampler` slot (matching SPIRV-Cross). The
fragment wrapper calls `main_impl(... set0.u, set0.tex, set0.texSmplr)`; the
compute kernel materialises local aliases (`constant U& u_1 = set0.u;`,
`texture2d<float> tex = set0.tex;`, `sampler texSmplr = set0.texSmplr;`) so
existing body emission keeps working without per-instruction rewrite.

`binding_shift` continues to apply to the outer `[[buffer(N)]]` of the
argument buffer itself (one per set); it does NOT apply to the `[[id]]` slots
inside.

Covered by `tests/msl_argbuf_tests.zig` (4 tests: struct emission, signature
shape, sequential `[[id]]` slots, default-false negative control).

### Task 6.2: CLI flag for `--msl-argument-buffers` — SHIPPED

Shipped in this commit. `glslpp msl <input> --msl-argument-buffers` plumbs
through to `spirvToMSL({ .argument_buffers = true, ... })`. Help text updated.

### Task 6.v2 — Argument buffers v2 (DEFERRED from M6 v1)

The v1 surface above covers the canonical drop-in case (set 0, UBO + sampled
image, fragment + compute). The following items are intentionally deferred:

- [ ] **Task 6.v2.a — Multiple descriptor sets**
  Today v1 emits a single `spvDescriptorSetBuffer0`; resources from `set=1`,
  `set=2`, etc. would all collapse into set 0 because `CbufferDecl` /
  `TextureDecl` don't track the set index. Acceptance: a fixture with
  `layout(set=0, binding=0) uniform A` and `layout(set=1, binding=0) uniform
  B` emits two structs (`spvDescriptorSetBuffer0` and
  `spvDescriptorSetBuffer1`) and two entry-point parameters (`set0
  [[buffer(0)]]`, `set1 [[buffer(1)]]`).

- [ ] **Task 6.v2.b — Storage buffers in the set struct**
  Today v1 keeps SSBOs on the legacy per-resource binding path even when
  `argument_buffers = true`, because the canonical fixture doesn't exercise
  SSBOs and adding them cleanly requires the same set-tracking work as
  v2.a. Acceptance: a compute shader with `layout(set=0, binding=0) buffer
  Buf { ... } sb;` and `--msl-argument-buffers` emits
  `device Buf* sb [[id(0)]];` inside `spvDescriptorSetBuffer0` and removes
  the standalone `device Buf* sb [[buffer(0)]]` parameter.

- [ ] **Task 6.v2.c — Storage images / subpass inputs in the set struct**
  Out of scope for v1 (the existing MSL backend doesn't emit storage images
  even in legacy mode — see M8 audit). Acceptance follows v2.b once storage
  images are handled at all.

- [ ] **Task 6.v2.d — Body rewrite for direct resource refs (cleanup)**
  v1's compute path materialises local aliases (`constant U& u_1 =
  set0.u;`) so the body emitter can keep using the legacy names. This is
  semantically equivalent and matches what SPIRV-Cross does internally with
  its name remapper, but a cleaner v2 would emit `set0.u` references
  directly from the body emitter and drop the alias declarations.
  Acceptance: kernel body emits `set0.u_1.c` instead of pre-declaring
  `u_1`. Non-blocking — purely cosmetic.

---

## Milestone 7 — C ABI surface

Confirmed entirely missing. This is the biggest single unlock for non-Zig adopters.

### Task 7.1: Define the C header

**Files:**
- Create: `include/glslpp.h`

- [ ] **Step 1: Write the header by hand**

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
      uint32_t version;
      int is_essl;
  } glslpp_compile_options_t;

  glslpp_status_t glslpp_compile(
      const char* glsl_source, size_t glsl_len,
      const glslpp_compile_options_t* opts,
      uint32_t** spirv_words, size_t* spirv_word_count);

  glslpp_status_t glslpp_to_hlsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int shader_model,
      char** hlsl, size_t* hlsl_len);

  glslpp_status_t glslpp_to_glsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int glsl_version,
      char** glsl, size_t* glsl_len);

  glslpp_status_t glslpp_to_msl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      int msl_version, int argument_buffers,
      char** msl, size_t* msl_len);

  glslpp_status_t glslpp_to_wgsl(
      const uint32_t* spirv_words, size_t spirv_word_count,
      char** wgsl, size_t* wgsl_len);

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

- [ ] **Step 2: Commit**

### Task 7.2: Implement the C ABI in Zig

**Files:**
- Create: `src/c_abi.zig`
- Modify: `build.zig` to add a `c-lib` step producing shared + static libs

- [ ] **Step 1: Write a Zig integration test that calls the exported functions**

  Use `tests/c_abi_tests.zig` calling the exported Zig functions directly (cross-language smoke is task 7.3).

- [ ] **Step 2: Implement c_abi.zig**

  Use a length-prefix trick to make `glslpp_free_u32` work with bare pointers: allocate `8 + n*4` bytes, store `n` at offset 0, return pointer at offset 8. Free by reading the length-prefix and freeing the original allocation.

  ```zig
  // SPDX-License-Identifier: MIT OR Apache-2.0
  const std = @import("std");
  const glslpp = @import("root.zig");

  threadlocal var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
  fn alloc() std.mem.Allocator { return gpa.allocator(); }

  pub const glslpp_status_t = c_int;
  pub const GLSLPP_OK: glslpp_status_t = 0;
  // ... (mirror header)

  // Implementation detail: store [length:u64][bytes...] so caller can free
  // without knowing the size.
  fn allocSized(bytes: usize) ![*]u8 {
      const a = alloc();
      const buf = try a.alloc(u8, 8 + bytes);
      std.mem.writeInt(u64, buf[0..8], @as(u64, @intCast(bytes)), .little);
      return buf.ptr + 8;
  }

  fn freeSized(p: ?[*]u8) void {
      if (p) |raw| {
          const start = raw - 8;
          const n = std.mem.readInt(u64, start[0..8], .little);
          alloc().free(start[0 .. 8 + @as(usize, @intCast(n))]);
      }
  }

  export fn glslpp_compile(...) callconv(.C) glslpp_status_t { ... }
  export fn glslpp_to_hlsl(...) callconv(.C) glslpp_status_t { ... }
  // ... etc.
  ```

- [ ] **Step 3: Wire build.zig**

  Add `c-lib` step producing both `.a` (static) and `.so`/`.dll`/`.dylib` (shared) artifacts.

- [ ] **Step 4: Verify, commit**

### Task 7.3: End-to-end C consumer

**Files:**
- Create: `examples/c/main.c`
- Modify: `build.zig` to add `c-example` step that compiles and links the C file
- Modify: `.github/workflows/ci.yml` to run the C example on every PR

- [ ] **Step 1: Write `examples/c/main.c`** that calls `glslpp_compile` + `glslpp_to_hlsl`, prints SPIR-V word count and HLSL output, frees both.

- [ ] **Step 2: Build it via Zig (using `b.addExecutable` with `.files = &.{ "examples/c/main.c" }` and `.link_libc = true`, linking the shared C lib).**

- [ ] **Step 3: Run it, verify output**

- [ ] **Step 4: Add CI job**

  ```yaml
  c-abi:
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

---

## Milestone 8 — Closing the loop

### Task 8.1: Scalar block layout (`GL_EXT_scalar_block_layout`)

**Files:**
- Modify: `src/preprocessor.zig` known-extension list
- Modify: `src/codegen.zig` `layoutAlignment` / `layoutSize` / `layoutArrayStride` to gate on `is_scalar`
- Test: new `tests/scalar_layout_tests.zig`

- [ ] **Step 1: Write failing test** comparing emitted offsets for the same struct with vs without `#extension GL_EXT_scalar_block_layout : require`

- [ ] **Step 2: Add `is_scalar: bool` to the layout context; when true, `layoutAlignment` returns 1 for member alignment, matching scalar packing rules**

- [ ] **Step 3: Verify, commit**

### Task 8.2: Recognize `GL_EXT_buffer_reference` extension

**Files:**
- Modify: `src/preprocessor.zig` known-extension list
- Test: `tests/buffer_ref_tests.zig`

- [ ] **Step 1: Currently the extension isn't in the known list — it's silently rejected. Add it.**

- [ ] **Step 2: Write test asserting `#extension GL_EXT_buffer_reference : require` does not produce an unknown-extension diagnostic** (and that subsequent buffer-reference syntax compiles correctly using the existing parser/codegen support)

- [ ] **Step 3: Verify, commit**

### Task 8.3: Descriptor remap for non-HLSL backends

**Files:**
- Modify: `src/root.zig` — add `binding_shift: i32 = 0` to `SpirvToGlslOptions`, `SpirvToMslOptions`, `SpirvToWgslOptions`
- Modify: each cross-compiler to honour it
- Test: per-backend tests

- [ ] **Step 1-N:** Mirror existing HLSL pattern in each backend, with a small test per backend.

### Task 8.4: Library-vs-library benchmark

**Files:**
- Create: `tools/bench_lib_vs_lib.zig`
- Modify: `build.zig` to optionally build/link `libglslang.a` + `libspirv-cross.a`

- [ ] **Step 1: Add build infrastructure**

  Easiest path: `git submodule add` of glslang + SPIRV-Cross, configure their CMakes to produce static archives, link via Zig's C interop. Document any platform-specific quirks.

  Fallback: shim that uses `LoadLibrary`/`dlopen` to load the installed Vulkan SDK's `libglslang.dll` at runtime.

- [ ] **Step 2: Mirror `tools/bench_compare.zig` structure but using in-process function calls instead of subprocess**

- [ ] **Step 3: Add results to BENCHMARKS.md**

- [ ] **Step 4: Add a `bench-lib` build step**

### Task 8.5: Populate `tests/external/` corpus for naga validation

**Files:**
- Modify: `tests/external/README.md` (or create) — instructions for fetching a public WGSL test corpus
- Modify: `tests/realworld_tests.zig` — if needed

- [ ] **Step 1: Audit current `tests/external/` directory state**

- [ ] **Step 2: Either add real shaders directly (small set) or add a fetch script that pulls a known corpus (e.g., a few canonical Naga test cases or a curated subset of SPIRV-Cross fixtures)**

- [ ] **Step 3: Verify `mise exec -- zig build test-realworld` actually runs naga validation against multiple shaders. Record the pass rate. Add to TEST_COVERAGE.md.**

- [ ] **Step 4: Commit**

---

## Acceptance criteria (after every milestone)

```bash
# All must remain green (with adjusted baselines as work lands):
mise exec -- zig build test --summary all          # 1640+ pass after M1 (added orphaned tests)
mise exec -- zig build test-hlsl --summary all     # 780+ pass
mise exec -- zig build conformance                 # 2087+ PASS
mise exec -- zig build fuzz -- --count 5000        # 5000 pass, 0 crashes
mise exec -- zig build examples                    # builds
mise exec -- env GLSLPP_BENCH_GLSLANG=... GLSLPP_BENCH_SPIRVX=... zig build bench-compare
```

Any regression in those numbers is a **STOP**: roll back and investigate.

## Estimated effort

| Milestone | Tasks | Rough duration |
|---|---:|---|
| 1 Repair test infrastructure | 4 | 2 h |
| 2 Reflection completion | 5 | 0.5–1 day |
| 3 Spec constants completion | 6 | 2 days (3.5 is the long pole) |
| 4 WGSL final opcode coverage | 2 | 0.5 day |
| 5 HLSL polish | 3 | 1 day |
| 6 MSL argument buffers | 2 | 1 day |
| 7 C ABI | 3 | 1.5–2 days |
| 8 Closing the loop | 5 | 2–4 days (8.4 dominates) |

**Total:** **~30 tasks, ~1 week of focused work** for a single competent contributor. Significantly smaller than the prior plan's 50-task / 2–3-week estimate because the prior plan duplicated already-shipped G1/G2/G3/G4/G5 work.

## Self-review notes

- **Spec coverage:** every genuine gap from the second-pass audit has a task. Items already shipped have been removed.
- **No placeholders:** every step lists either exact code, exact bash, or exact files. Task 8.4 (library-vs-library benchmark) intentionally leaves the C++ build details flexible because they depend on platform; a fallback path is named.
- **Type consistency:** `SpecOverride`, `glslpp_status_t`, `glslpp_compile_options_t`, `ImageFormat`, `expectDiagnostic` are consistent across tasks.

## Execution handoff

Plan revised and saved to `docs/roadmap/2026-05-26-drop-in-replacement-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review checkpoints, fast iteration.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, batch with checkpoints.

Already in flight from this session: **M0.1 (expectDiagnostic helper)** is committed at `4742d229`. Marked done in tracker even though M0 is no longer a milestone in this revised plan — the helper is still useful for any future diagnostic-tests work.
