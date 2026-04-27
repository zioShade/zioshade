# Quality Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all quality issues discovered during validation: broken unit tests, preprocessor hang, memory leaks, and add differential testing.

**Architecture:** Four independent workstreams: (1) Fix error recovery over-suppression in semantic.zig, (2) Fix infinite loop in preprocessor __LINE__ expansion, (3) Fix memory leaks in parser/semantic/codegen deinit paths, (4) Add spirv-dis based differential testing against glslangValidator.

**Tech Stack:** Zig 0.15.2, spirv-val, spirv-dis, glslangValidator (all from Vulkan SDK 1.4.341.1)

---

## Task 1: Fix Error Recovery Over-Suppression

**Problem:** `analyzeFunction()` catches ALL errors from `analyzeStatement()` with `catch { break; }` at semantic.zig:775. This swallows `UndeclaredIdentifier` and `TypeMismatch` for invalid code, making the compiler silently produce SPIR-V for programs that should fail.

**Root cause:** The error recovery was added to handle shaders where partial analysis should still produce output (e.g., after a return statement, or for complex constructs not yet supported). But it catches real errors too.

**Files:**
- Modify: `src/semantic.zig:775` (the `catch { break; }` in `analyzeFunction`)

- [ ] **Step 1: Add an error suppression flag to the Analyzer struct**

In `src/semantic.zig`, add a field `suppress_errors: bool = false` to the `Analyzer` struct (around line 80-110 where the struct fields are defined).

- [ ] **Step 2: Gate the catch block on the suppress_errors flag**

Change the error recovery at line 775 from:
```zig
self.analyzeStatement(child) catch {
    // Semantic error: stop processing this function but keep what we have
    break;
};
```
to:
```zig
self.analyzeStatement(child) catch |err| {
    if (self.suppress_errors) {
        break;
    } else {
        return err;
    }
};
```

- [ ] **Step 3: Set suppress_errors = true only in compileToSPIRV (production path)**

In `src/root.zig`, after the semantic.analyze call, we need to make the error recovery opt-in. The cleanest approach: don't suppress errors at all initially — let the conformance suite tell us if any shaders regress.

Actually, the better approach is simpler: just remove the catch-and-break entirely. If a shader has a semantic error, the compiler should fail. The 197 valid test files should all pass semantic analysis without needing error recovery.

Change line 775 to just:
```zig
try self.analyzeStatement(child);
```

- [ ] **Step 4: Run unit tests for semantic.zig**

Run: `timeout 30 zig test src/semantic.zig 2>&1 | grep -E 'FAIL|OK|leak'`
Expected: The 2 previously-failing tests now pass (type error and undeclared identifier tests).

- [ ] **Step 5: Run conformance suite to check for regressions**

Run: `bash autoresearch.sh`
Expected: 197/197 still passes (all valid shaders analyze without errors).

If regressions occur, investigate which shader(s) fail and fix the root cause in the semantic analyzer rather than re-enabling the blanket catch.

---

## Task 2: Fix Preprocessor __LINE__ Hang

**Problem:** `preprocessor.zig` test `__LINE__ builtin` hangs (killed at 30s timeout). Likely an infinite loop when expanding `__LINE__` macro.

**Files:**
- Modify: `src/preprocessor.zig` (the `__LINE__` expansion logic around line 177)

- [ ] **Step 1: Read the preprocessor __LINE__ handling code and identify the loop**

Read `src/preprocessor.zig` around line 177 and the `process()` function to understand the control flow.

- [ ] **Step 2: Fix the infinite loop**

The most likely cause: `__LINE__` expands to a token that gets re-processed, which contains `__LINE__` again, creating an infinite cycle. Add a guard to prevent re-expansion of built-in macros.

- [ ] **Step 3: Run preprocessor tests**

Run: `timeout 30 zig test src/preprocessor.zig 2>&1 | tail -10`
Expected: All 30 tests pass without hanging.

---

## Task 3: Fix Memory Leaks in Parser, Semantic, Codegen

**Problem:** GPA detects 38 memory leaks across parser (1), semantic (16), codegen (21). The `deinit()` paths are incomplete — allocated strings, slices, and instructions aren't freed.

**Files:**
- Modify: `src/parser.zig` (freeTree / deinit path)
- Modify: `src/semantic.zig` (Analyzer.deinit, ir.Module.deinit)
- Modify: `src/codegen.zig` (generate function cleanup)

- [ ] **Step 1: Get detailed leak traces for parser.zig**

Run: `timeout 30 zig test src/parser.zig 2>&1 | grep -B2 'leaked'`
Expected: Stack traces showing which allocations leak.

- [ ] **Step 2: Fix parser.zig leaks**

Fix the `freeTree` function or the test teardown to free the leaked allocation (likely the `dupe` in `parseStructDecl` at line 504).

- [ ] **Step 3: Get detailed leak traces for semantic.zig**

Run: `timeout 30 zig test src/semantic.zig 2>&1 | grep -B5 'leaked' | head -40`

- [ ] **Step 4: Fix semantic.zig leaks**

The main leak sources:
- `injectBuiltins()` allocates strings for builtin names that are never freed
- `overloads` HashMap entries are never freed
- Instruction operand slices allocated per-instruction
- `types` HashMap entries

Ensure `Analyzer.deinit()` frees all owned memory.

- [ ] **Step 5: Get detailed leak traces for codegen.zig**

Run: `timeout 30 zig test src/codegen.zig 2>&1 | grep -B5 'leaked' | head -40`

- [ ] **Step 6: Fix codegen.zig leaks**

The main leak sources:
- `emitExtensions()` allocates extension strings
- Operand slices in generated instructions
- String allocations for debug info

Ensure `generate()` or its callers properly free all temporary allocations.

- [ ] **Step 7: Run all module tests to verify zero leaks**

Run all three tests:
```
timeout 30 zig test src/parser.zig 2>&1 | grep -E 'leak|All.*passed'
timeout 30 zig test src/semantic.zig 2>&1 | grep -E 'leak|All.*passed'
timeout 30 zig test src/codegen.zig 2>&1 | grep -E 'leak|All.*passed'
```
Expected: All pass with zero leak messages.

---

## Task 4: Add Differential Testing Against glslangValidator

**Problem:** `spirv-val` only checks structural validity, not semantic correctness. We need to verify our SPIR-V output is semantically equivalent to a reference compiler.

**Approach:** For each valid test shader, compile with both glslpp and glslangValidator, disassemble both with `spirv-dis`, and compare the instruction sequences. We can't expect identical output, but we can check for:
1. Same number and types of arithmetic/logical operations
2. Same entry point signature
3. Same variable types and decorations

**Files:**
- Modify: `tests/runner.zig` (add differential comparison mode)
- Modify: `build.zig` (add diff-test step)

- [ ] **Step 1: Compile a few test shaders with glslangValidator and capture SPIR-V disassembly**

Run glslangValidator on a handful of test shaders, capture the .spv output, and run spirv-dis on it to see the reference output format:
```
glslangValidator -V tests/glslang-430/minimal_test.frag -o /tmp/ref.spv
spirv-dis /tmp/ref.spv
```

- [ ] **Step 2: Build a differential comparison script**

Add a function to `tests/runner.zig` that:
1. Compiles a shader with glslpp → spirv-dis
2. Compiles the same shader with glslangValidator → spirv-dis
3. Strips IDs and labels from both (they'll differ)
4. Compares the instruction structure

- [ ] **Step 3: Add a `diff-test` step to build.zig**

Add `zig build diff-test` that runs the differential comparison against all valid shaders.

- [ ] **Step 4: Run differential test and analyze results**

Run the diff test and categorize differences as:
- **Cosmetic** (ID numbering, label ordering)
- **Structural** (different instruction types, missing operations)
- **Semantic** (same structure but different constant values)

- [ ] **Step 5: Commit**

Commit the differential testing infrastructure even if some differences are found. The test serves as a baseline for future correctness improvements.

---

## Execution Order

1. **Task 1** first — fixing error recovery is critical and quick. Run conformance suite to verify.
2. **Task 2** — preprocessor hang fix is isolated and quick.
3. **Task 3** — memory leaks are the most tedious but important for production quality.
4. **Task 4** — differential testing is the longest task but adds the most long-term value.
