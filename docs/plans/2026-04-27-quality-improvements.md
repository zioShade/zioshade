# Quality Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all remaining quality gaps in the glslpp GLSL-to-SPIR-V compiler: correct sampler type codegen, preprocessor operators, crash guards, real differential testing, and proper error diagnostics.

**Architecture:** Seven independent tasks, each self-contained and testable. Tasks 1-3 fix correctness bugs where wrong SPIR-V is generated. Tasks 4-5 fix missing features. Tasks 6-7 add testing and UX infrastructure.

**Tech Stack:** Zig 0.15.2, spirv-val, spirv-dis, glslangValidator (all from Vulkan SDK 1.4.341.1)

**Build command:** `zig build-exe -ODebug --dep glslpp -Mroot=tests/runner.zig -Mglslpp=src/root.zig --cache-dir .zig-cache -femit-bin=.zig-cache/bin/conformance-runner.exe`

**Test commands:**
- Per-module: `timeout 30 zig test src/<module>.zig`
- Conformance: `bash autoresearch.sh`
- Diff test: `bash diff_test.sh`

---

## Task 1: Add sampler3D and sampler2DArray as Distinct Types — ✅ DONE

**Problem:** Parser maps `sampler3D` → `.sampler2d` and `sampler2DArray` → `.sampler2d`. Codegen then produces `OpTypeImage` with `Dim=2D` instead of `Dim=3D` or `Dim=2D+Arrayed=1`. Shaders using `texture()` on these types produce invalid GPU behavior.

**Files:**
- Modify: `src/ast.zig` (add `sampler3d`, `sampler2d_array` types to the Type enum)
- Modify: `src/parser.zig` (map `kw_sampler3d` → `.sampler3d`, `kw_sampler2d_array` → `.sampler2d_array`)
- Modify: `src/semantic.zig` (add result types for texture ops on these types)
- Modify: `src/codegen.zig` (emit correct Dim/Arrayed for these types in `ensureType`)

- [ ] **Step 1: Add AST types**

In `src/ast.zig`, add two new enum values to `Type` after `.sampler2d`:
```zig
sampler2d_array,
sampler3d,
```

Then update all the switch statements in `ast.zig` that list all sampler types (there are ~5 of them: `numComponents`, `isScalar`, `isFloat`, `isSampler`, `isImage`). Add `.sampler2d_array` and `.sampler3d` to the same branches as `.sampler2d`.

- [ ] **Step 2: Fix parser mappings**

In `src/parser.zig`, change the `tryType()` function:
```zig
// Line 361: change from .sampler2d to .sampler2d_array
.kw_sampler2d_array => { _ = self.advance(); return .sampler2d_array; },
// Line 364: change from .sampler2d to .sampler3d
.kw_sampler3d => { _ = self.advance(); return .sampler3d; },
```

- [ ] **Step 3: Add codegen for sampler3d**

In `src/codegen.zig`, in the `ensureType` function's switch, add cases for `.sampler3d` and `.sampler2d_array`. Use the existing `.isampler3d` handler as a template (it emits `Dim = 2` which is 3D). For `sampler3d`:
- `Dim = 2` (3D)
- `Depth = 0` (not a depth sampler)
- `Arrayed = 0`
- `MS = 0`
- `Sampled = 1`
- Sampled type: `float` (not int/uint)

For `sampler2d_array`:
- `Dim = 1` (2D)
- `Depth = 0`
- `Arrayed = 1` ← the key difference
- `MS = 0`
- `Sampled = 1`
- Sampled type: `float`

Find the `.sampler2d` handler and copy it, changing only the Dim/Arrayed values. Save the inner image ID (needed for `extract_image`).

- [ ] **Step 4: Update semantic result types**

In `src/semantic.zig`, find `samplerResultType()` (or wherever texture call result types are determined). Add `.sampler3d` and `.sampler2d_array` to return `.vec4` (same as `.sampler2d`).

- [ ] **Step 5: Update extract_image in codegen**

In `src/codegen.zig`, find where `extract_image` selects the inner image ID for texture operations. Add `.sampler3d` and `.sampler2d_array` to use the new inner IDs saved in Step 3.

- [ ] **Step 6: Run tests**

```
timeout 30 zig test src/ast.zig
timeout 30 zig test src/semantic.zig
timeout 30 zig test src/codegen.zig
bash autoresearch.sh
```

Expected: All module tests pass, 197/197 conformance maintained (these test shaders don't use sampler3D/sampler2DArray directly, but existing sampler2D behavior must not regress).

---

## Task 2: Add Stack Overflow Protection for Recursive Types — ✅ DONE

**Problem:** `buffer-reference.nocompat.vk.comp` has `Node` type that contains `Node next` (self-referential). This causes infinite recursion in semantic analysis → stack overflow → crash.

**Files:**
- Modify: `src/semantic.zig` (add depth guard to `analyzeExpression` or `collectTopLevel`)

- [ ] **Step 1: Identify the recursion point**

Run the crashing file:
```
timeout 5 .zig-cache/bin/conformance-runner.exe tests/spirv-cross/buffer-reference.nocompat.vk.comp
```

The crash is in semantic analysis when processing named types recursively. The type `Node` has members of type `Node`, which triggers infinite type resolution.

- [ ] **Step 2: Add a visited set for type resolution**

Add a field to `Analyzer`:
```zig
type_depth: u32 = 0,
```

In `analyzeExpression` or wherever named types are resolved (the code that looks up `self.types.get(struct_name)` and iterates members), increment `type_depth` on entry and check it:
```zig
self.type_depth += 1;
defer self.type_depth -= 1;
if (self.type_depth > 16) return error.SemanticFailed;
```

- [ ] **Step 3: Verify the crash is fixed**

```
timeout 5 .zig-cache/bin/conformance-runner.exe tests/spirv-cross/buffer-reference.nocompat.vk.comp
```

Expected: No crash (compiles or returns error gracefully). Also verify no regression:
```
bash autoresearch.sh
```

- [ ] **Step 4: Run all module tests**

```
timeout 30 zig test src/semantic.zig
timeout 30 zig test src/codegen.zig
```

---

## Task 3: Complete the Differential Test (Actual Op Comparison)

**Problem:** `diff_test.sh` counts matches but doesn't actually compare normalized Op sequences. We need to know if our SPIR-V is semantically equivalent to glslangValidator's output.

**Files:**
- Modify: `diff_test.sh` (add actual diff comparison)
- Modify: `src/root.zig` (expose a way to get the raw SPIR-V words without writing to a file — optional, or use temp file)

- [ ] **Step 1: Modify the runner to save .spv on pass**

In `tests/runner.zig`, change the `testShader` function to keep the `.spv` file (don't delete it) when it passes, or write it to a predictable path like `.zig-cache/last-pass.spv`.

Alternatively, add a `--save-spv <path>` flag to the runner.

- [ ] **Step 2: Update diff_test.sh to disassemble our output**

After confirming both compilers produce valid SPIR-V:
1. Disassemble reference: `spirv-dis /tmp/ref.spv`
2. Disassemble ours: `spirv-dis .zig-cache/last-pass.spv`
3. Normalize both (strip IDs, labels, debug info, name decorations)
4. Compare normalized output

Normalization script:
```bash
normalize_dis() {
    grep -v '^;' | grep -v '^$' | \
    grep -v 'OpName' | grep -v 'OpMemberName' | grep -v 'OpSource' | \
    grep -v 'OpString' | grep -v 'OpModuleProcessed' | \
    sed 's/%[a-zA-Z_][a-zA-Z0-9_]*/%N/g' | \
    sed 's/%[0-9]*/%ID/g'
}
```

- [ ] **Step 3: Classify differences**

For each shader where both produce valid SPIR-V, compare normalized output:
- **MATCH**: Normalized output is identical → ✅
- **STRUCTURAL_DIFF**: Different Op types or counts → flag for investigation
- **COSMETIC_DIFF**: Same Ops but different ordering → acceptable

Output a summary like:
```
MATCH:           120
STRUCTURAL_DIFF:  46
COSMETIC_DIFF:     0
```

- [ ] **Step 4: Run the full diff and report**

```bash
bash diff_test.sh 2>&1 | tee diff_report.txt
```

The report becomes a baseline for future correctness improvements.

- [ ] **Step 5: Commit**

```bash
git add diff_test.sh tests/runner.zig
git commit -m "Complete differential testing: actual Op comparison against glslangValidator"
```

---

## Task 4: Implement Stringify (#) Preprocessor Operator — ✅ DONE

**Problem:** Test `"stringify operator"` fails with `InvalidToken`. The `#` token in macro body `#x` is not recognized as the stringify operator.

**Files:**
- Modify: `src/preprocessor.zig` (handle `#` in function-like macro body expansion)

- [ ] **Step 1: Understand the test**

Test source: `#define STR(x) #x\nint x = STR(hello);`
Expected: `STR(hello)` expands to `"hello"` (a string literal token).

The issue: when `parseDefine` parses the macro body `#x`, it likely fails because `#` is not a valid token inside a macro body. The lexer produces a `pp_define` or `hash` token.

- [ ] **Step 2: Handle `#` in macro body parsing**

In `parseDefine()` (around line 150), when parsing function-like macro body tokens, recognize `#` followed by an identifier as the stringify operator. Instead of emitting the raw tokens, record a "stringify parameter N" instruction.

The simplest approach: during macro expansion (not parsing), when we encounter `#` in the body followed by a parameter name, convert the argument tokens to a string literal.

- [ ] **Step 3: Implement stringify during expansion**

In `expandFunctionMacro()` (the function that substitutes parameters with arguments):
1. When processing body tokens, check if a token is `#` (hash/pound).
2. If so, the next token should be a parameter name.
3. Convert the corresponding argument's text to a string literal token.

- [ ] **Step 4: Run the test**

```
timeout 30 zig test src/preprocessor.zig 2>&1 | grep 'stringify'
```

Expected: `preprocessor.test.stringify operator...OK`

- [ ] **Step 5: Verify no regression**

```
bash autoresearch.sh
```

---

## Task 5: Implement Token Paste (##) Preprocessor Operator — ✅ DONE

**Problem:** Test `"token paste operator"` fails with `InvalidToken`. The `##` operator in `a##b` should concatenate tokens `a` and `b` into `ab`.

**Files:**
- Modify: `src/preprocessor.zig` (handle `##` in macro body expansion)

- [ ] **Step 1: Understand the test**

Test source: `#define PASTE(a,b) a##b\nint x = PASTE(foo,bar);`
Expected: `PASTE(foo,bar)` expands to `foobar` (an identifier token).

- [ ] **Step 2: Handle `##` during macro body parsing**

When `parseDefine` encounters `##` in a function-like macro body, record it as a paste operator. The body becomes a sequence of: parameter-ref, paste, parameter-ref.

- [ ] **Step 3: Implement paste during expansion**

During `expandFunctionMacro`:
1. When processing body tokens, detect `##` between two tokens.
2. Concatenate the text of the left and right operands.
3. Re-tokenize the result (or just emit it as a single identifier).

- [ ] **Step 4: Run the test**

```
timeout 30 zig test src/preprocessor.zig 2>&1 | grep 'paste'
```

Expected: `preprocessor.test.token paste operator...OK`

- [ ] **Step 5: Run all preprocessor tests**

```
timeout 30 zig test src/preprocessor.zig
```

Expected: 30/30 pass.

---

## Task 6: Implement Proper Error Diagnostics — ✅ DONE

**Problem:** `compileToSPIRVWithDiagnostics` is a stub. `last_compile_detail` only says "semantic_failed". Users need "line 42: undeclared identifier 'foo'" messages.

**Files:**
- Modify: `src/semantic.zig` (record line/column with errors)
- Modify: `src/root.zig` (implement `compileToSPIRVWithDiagnostics`)
- Modify: `src/diagnostic.zig` (already has the struct, may need minor updates)

- [ ] **Step 1: Track error location in semantic analysis**

In `src/semantic.zig`, the `errdefer` blocks in `analyzeStatement` and `analyzeExpression` already set `last_error_ctx` and `last_error_inner`. Add line tracking:

Add a threadlocal:
```zig
pub threadlocal var last_error_line: u32 = 0;
pub threadlocal var last_error_column: u32 = 0;
```

Set these in the `errdefer` blocks using `node.loc.line` and `node.loc.column`.

- [ ] **Step 2: Build human-readable error messages**

Add a function:
```zig
pub fn lastErrorMessage() []const u8 {
    // Returns a static string describing the last error
    // e.g., "line 42: undeclared identifier 'x'"
    // Uses last_error_ctx, last_error_inner, last_error_line
}
```

Use a threadlocal buffer to format the message.

- [ ] **Step 3: Implement compileToSPIRVWithDiagnostics**

In `src/root.zig`, implement the stub function. On compile failure:
1. Create a `Diagnostic` with the error kind, line, column, and message.
2. Append to the diagnostics list.

```zig
const detail = last_compile_detail orelse .semantic_failed;
const msg = std.fmt.allocPrint(alloc, "{s}: {s}", .{@tagName(detail), semantic.last_error_inner}) catch "unknown error";
try diagnostics.append(alloc, .{
    .kind = .@"error",
    .line = semantic.last_error_line,
    .column = semantic.last_error_column,
    .message = msg,
});
```

- [ ] **Step 4: Add a unit test for diagnostics**

In `src/root.zig`:
```zig
test "compileToSPIRVWithDiagnostics reports error location" {
    const alloc = std.testing.allocator;
    var diags = std.ArrayListUnmanaged(diagnostic.Diagnostic){};
    defer { for (diags.items) |d| alloc.free(d.message); diags.deinit(alloc); }

    const result = compileToSPIRVWithDiagnostics(
        alloc, "void main() { float y = x; }", .{.stage = .fragment}, &diags
    );
    try std.testing.expect(result == error.SemanticFailed);
    try std.testing.expect(diags.items.len > 0);
    try std.testing.expect(diags.items[0].line > 0);
}
```

- [ ] **Step 5: Run tests**

```
timeout 30 zig test src/root.zig
timeout 30 zig test src/semantic.zig
bash autoresearch.sh
```

---

## Task 7: Fix Ghostty Shader Compilation (31 Reference Failures)

**Problem:** 31 valid test shaders fail glslangValidator reference compilation. Most are Ghostty shaders needing `#include` support or proper stage detection. Some may be spirv-cross shaders needing features we haven't implemented.

**Files:**
- Investigate first, then modify appropriate files

- [ ] **Step 1: Categorize the 31 failures**

Run glslangValidator on each of the 31 failing shaders and capture the error:
```bash
while IFS=' ' read -r status file; do
    [ "$status" != "VALID" ] && continue
    if ! glslangValidator -V "$file" -o /dev/null 2>/dev/null; then
        echo "FAIL: $file"
        glslangValidator -V "$file" 2>&1 | head -3
    fi
done < .zig-cache/ref_classification.txt
```

Categorize into:
- **Missing stage flag** (`.glsl` files needing `-S frag/vert/comp`)
- **Missing `#include`** (Ghostty files including `common.glsl`)
- **Unsupported GLSL features** (buffer_reference, etc.)
- **glslang bugs** (rare)

- [ ] **Step 2: Fix stage detection for .glsl files**

The diff_test.sh script already has stage detection for `.f.glsl`/`.v.glsl`/`.c.glsl`. Verify all Ghostty files are handled correctly.

- [ ] **Step 3: Verify #include handling**

The runner already has `inlineIncludes()` for `#include "common.glsl"`. Verify it works for the Ghostty shaders. If not, debug the include path resolution.

- [ ] **Step 4: Fix or skip unsupported features**

For shaders using truly unsupported features (buffer_reference, etc.), they may need to be classified as SKIP in the reference classification.

- [ ] **Step 5: Re-run diff test**

```bash
bash diff_test.sh 2>&1 | tail -10
```

Expected: Reduction in reference failures (from 31 to as low as possible).

---

## Execution Order

1. **Task 1** (sampler3D/sampler2DArray) — correctness fix, no test shader depends on it but it prevents future GPU failures
2. **Task 2** (stack overflow guard) — crash fix, prevents DOS on malicious input
3. **Task 6** (error diagnostics) — UX improvement, helps users of the library
4. **Task 4** (stringify) — small preprocessor feature
5. **Task 5** (token paste) — small preprocessor feature
6. **Task 3** (differential test) — depends on Tasks 1-5 being done for best results
7. **Task 7** (Ghostty shaders) — depends on differential test to verify fixes
