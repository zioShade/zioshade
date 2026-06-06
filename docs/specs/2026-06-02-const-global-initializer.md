# Spec: module-scope `const` global initializers are dropped (frontend silent-wrong)

**Status:** frontend + GLSL/HLSL/WGSL done (2026-06-06); MSL follow-up
**Severity:** silent-wrong, **all backends** (the SPIR-V itself is wrong)
**Witnesses:** `tests/spirv-cross/lut-promotion.frag`, `tests/spirv-cross/constant-array.frag`

## Progress

- **Frontend (Design A) + GLSL + HLSL** — PR #158 (`6dfb1961`).
- **WGSL** — done 2026-06-06. Two fixes shipped together (the has_load
  widening alone would convert an honest naga-reject into a silent-wrong zero-init):
  1. The Private-var "is used" check (`spirv_to_wgsl.zig`) now also counts an
     `OpAccessChain` whose base (`words[3]`) is the variable, so an array global
     reached only via `arr[i]` is declared (was skipped → dangling identifier).
  2. `resolveConstantExpr` resolves an `OpConstantComposite` by reusing the WGSL
     constructor literal `collectNames` already precomputes (`array<T,N>(...)`,
     `vecN<..>(..)`, `StructName(..)`, `matCxR..(..)`) — single source of truth,
     guarded by a `'('` check so a `vN`-placeholder (unspellable composite) returns
     null. The const-emit path now FAILS LOUD (`error.UnsupportedOp`) when an
     initializer cannot be lowered, never zero-initialises (silent-wrong).
  Regression test: `tests/wgsl_tests.zig` "module-scope const array indexed at
  runtime emits materialized array literal" (asserts the `const LUT: array<f32,4>
  = array<f32,4>(...)` literal + naga-valid). Minimal witness used (not the two
  spirv-cross fixtures) because those trip the orthogonal def-drop below.
- **MSL** — still a follow-up.

## ⚠ Orthogonal pre-existing bug — WGSL local-array index def-drop (NOT this fix)

`tests/spirv-cross/{constant-array,lut-promotion}.frag` still fail to fully
naga-validate after the const-global fix, for a **separate** reason. They use
*function-local* `const` arrays (already declared as `var v = array<..>(..)`),
and a single `%27 = OpLoad %int %index` is rendered **inconsistently**: as the
input name `index` in the primary emission path but as its raw generated name
`v20` inside a **recomputed** sub-expression (the running sum
`foo[index] + foobars[index][index+1]` is redundantly recomputed for later `+`
terms, triggered by the `resolve(...)` function-call argument re-evaluation), and
`let v20` is never emitted → naga `no definition in scope for identifier: v20`.
This is a WGSL expression-emission / CSE bug (load-of-input naming + sub-expr
recompute), independent of the const-initializer path. Fix separately.

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
