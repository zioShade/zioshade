# Spec: module-scope `const` global initializers are dropped (frontend silent-wrong)

**Status:** proposed (2026-06-02)
**Severity:** silent-wrong, **all backends** (the SPIR-V itself is wrong)
**Witnesses:** `tests/spirv-cross/lut-promotion.frag`, `tests/spirv-cross/constant-array.frag`

## Problem

A module-scope constant array indexed by a **runtime** value:
```glsl
const float LUT[16] = float[](1,2,3,4, 1,2,3,4, 1,2,3,4, 1,2,3,4);
layout(location=0) flat in int index;
void main(){ FragColor = LUT[index]; }   // dynamic index → can't constant-fold
```
glslpp lowers `LUT` to a **Private global `OpVariable` with no initializer and no
stores** — its 16 values appear *nowhere* in the emitted SPIR-V:
```
%LUT = OpVariable %_ptr_Private__arr_float_uint_16 Private      ← word-count 4, no init
%6   = OpAccessChain %_ptr_Private_float %LUT %5                ← reads uninitialised
```
Every backend then reads garbage. The WGSL backend additionally skips declaring
`LUT` (its "is used" check only looks for a direct `OpLoad`, not the
`OpAccessChain` array access — line ~1545 of `spirv_to_wgsl.zig`), so naga
reports `no definition in scope for identifier: LUT`. Even if declared, a
zero-initialised `var<private>` would be **the wrong values** — so the WGSL-side
"declare it" patch alone would convert a naga-reject into a naga-*pass*-but-wrong
silent-wrong, which is worse. The real fix is in the frontend.

## Oracle / reference (glslangValidator -V)

glslang does **not** make a Private global. It emits the constant composite once
and **materialises a Function-local `indexable` copy per dynamic access**:
```
%16        = OpConstantComposite %_arr_float_uint_16 %float_1 %float_2 ... (16 values)
%indexable = OpVariable %_ptr_Function__arr_float_uint_16 Function
             OpStore %indexable %16
%6         = OpAccessChain %_ptr_Function_float %indexable %index
```

## Root cause (glslpp)

1. `ir.Global` (`src/ir.zig` ~186) has **no `initializer` field** — the const
   initializer is lost at AST→IR lowering.
2. `Codegen.emitGlobals` (`src/codegen.zig` ~4049) always emits
   `encodeInstructionHeader(4, .Variable)` — never the optional 5th initializer
   operand.

## ⚠ Architectural finding (2026-06-02 — a first Design-A attempt, reverted)

A naive Design A **fails** and must NOT be shipped (it emits `spirv-val`-invalid
SPIR-V — forward reference `%LUT = OpVariable … Private %5` where `%5 has not
been defined`). Two facts make it fail:

1. **`Analyzer.instructions` is per-function scratch** (`semantic.zig` ~561/566:
   deinit'd, never assigned to the Module). Calling `analyzeExpression(initNode)`
   at global-decl time (`collectTopLevel`) folds the composite to an id but the
   `OpConstantComposite` instruction is **discarded** — never emitted.
2. **Codegen materialises its own constants** (`emitted_constants` /
   `type_section`, `codegen.zig` ~2823+) and ignores semantic-side constant ids
   for globals. A raw semantic id handed to `emitGlobals` references a constant
   codegen never emitted.

**Use the existing `spec_op_literals` pattern as the model.** The Module already
carries `spec_op_literals: []const SpecOpLiteralConst` (`ir.zig` ~86) — a
module-level list that "codegen lowers each to an OpConstant **before** the …
consumers, and also populates the codegen-side `emitted_constants` cache." Mirror
it with a `global_init_constants` list carrying the folded constant **values**
(not a semantic id); codegen emits each as `OpConstantComposite` in the constants
section, registers it in `emitted_constants`, then references it from the global
OpVariable. The hard part is carrying arbitrary (possibly nested) constant values
from semantic to the Module — `spec_op_literals` only models scalars, so this
needs a small recursive constant representation.

## Fix (two viable designs)

**Design A — initializer on the Private global (smaller SPIR-V):**
1. Add a module-level `global_init_constants` list (modeled on `spec_op_literals`)
   carrying the folded constant **values** + the global's result id, plus an
   `initializer_id` on `ir.Global`.
2. In AST→IR lowering, fold the `const` global's initializer to constant values
   and append to that list.
3. In `emitGlobals`, if present: codegen emits each entry as an
   `OpConstantComposite` (its own emitter, constants section) and the
   `OpVariable` with word-count **5** referencing it. `spirv-val` clean, Vulkan-legal.
   - Then the WGSL backend's existing initializer path (line ~1552) emits
     `const LUT: array<f32,16> = array<f32,16>(...)` for free; HLSL/MSL/GLSL get
     the values via their global-initializer paths.

**Design B — materialise like glslang (indexable Function local):**
   Lower a dynamic index into a `const` global to a Function-local temp + store of
   the constant composite. More faithful to glslang but a larger lowering change
   and bigger SPIR-V.

**Recommend Design A** — minimal, matches the IR's existing global model, and the
WGSL initializer path already exists.

## Secondary fix (independent, smaller — do alongside or after)

`spirv_to_wgsl.zig` line ~1542 "is used" check counts only direct `OpLoad`.
Extend it to also count `OpAccessChain`/`OpInBoundsAccessChain` whose **base**
(`words[3]`) is the variable, so array-typed Private globals are declared. (Once
Design A lands, the initializer makes them correct; until then this alone would
declare-but-zero, so gate it behind Design A or keep as a follow-up.)

## Verification
- `spirv-val` clean on the witnesses (already passes; correctness is the point).
- Dis the witness SPIR-V: `%LUT = OpVariable … Private %<init>` (word-count 5) and
  an `OpConstantComposite` carrying the 16 values.
- WGSL: `lut-promotion.frag` and `constant-array.frag` naga-validate
  (`const LUT: array<f32,16> = array<f32,16>(...)`).
- Per-shader byte-diff: only const-global shaders change; no regressions.
- `just test` / `conformance` PASS must not drop, FAIL must not grow.

## TDD
1. RED: a frag shader with a `const T arr[N]` indexed by a `flat in int`; assert
   the emitted SPIR-V contains an `OpConstantComposite` with the values and the
   global OpVariable has an initializer operand (dis + grep), and the WGSL
   naga-validates.
2. GREEN: Design A.
3. Oracle-gate: spirv-val + naga + the existing backend suites.

## Follow-up (LANDED): WGSL reloaded-value def-drop in recomputed sub-expressions

**Independent of the const-global work above** (those const arrays are
function-LOCAL and already declared as `var v17 = array<…>(…)`). This is a
distinct expression-emission / CSE bug surfaced by the same two witnesses.

### Symptom
`constant-array.frag` and `lut-promotion.frag` emitted WGSL that referenced an
undeclared `vN` (naga: `no definition in scope for identifier: vN`):

```wgsl
let v26: vec4f = v17[index] + v18[index][v22];      // direct path — uses `index`
let v29: vec4f = (v17[v20] + v18[v20][v22]) + v28;  // recomputed path — uses `v20` (undeclared)
```

The single `OpLoad %int %index` was rendered under TWO names — the input name
`index` in the direct emission path, but its raw generated `v20` inside a
sub-expression that the running sum was redundantly recomputed into (triggered by
re-evaluating function-call arguments). The `lut-promotion.frag` variant is the
same class for a reloaded OUTPUT (`FragColor += …`): a recomputed sub-expression
froze `OpLoad %FragColor` as a raw `vN`.

### Root cause
The load-name propagation (the `is_input_load` / `is_output_load` / `is_tex`
branches, plus the generic immutable-load value-name loop) ran ONLY at *emission*
time. But the AccessChain pre-scan and the arithmetic inline-expression pre-scan
freeze operands BY NAME *before* emission. So a reloaded input/output value was
captured in those frozen inline expressions under its default `vN`, while direct
emission used the real name — the same value under two names, one undeclared.

### Fix (`src/spirv_to_wgsl.zig`, `emitBody`)
Add a pre-pass that propagates DIRECT-variable load names BEFORE both pre-scans:
- Output / Input / texture loads propagate the variable name UNCONDITIONALLY
  (mirroring the emission branches; WGSL reads these by name at the use site).
- Other variables (Uniform/PushConstant/Private/Function) propagate only when the
  pointer is not a Store target, so mutable values still capture per-load.
- Loads of AccessChain results stay in the post-pre-scan value-name loop (their
  names depend on the expressions that pre-scan builds); that loop now skips ids
  already finalized by the pre-pass.

Result: every emission path binds a reloaded value to one consistent name. No
silent-wrong — `FragColor`/`index` are read by name at the same program point, so
recomputed sub-expressions are value-equivalent.

### Tests (`tests/wgsl_tests.zig`)
- "a reloaded input index keeps one name across recomputed sub-expressions"
  (constant-array.frag shape)
- "a reloaded output accumulator keeps one name across recomputed sub-expressions"
  (lut-promotion.frag shape)
Both assert `assertNoUndeclaredVTemp` + `nagaValidateOrSkip`. Conformance stays at
2076 PASS / 0 FAIL.
