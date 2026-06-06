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

## Fix (two viable designs)

**Design A — initializer on the Private global (smaller SPIR-V):**
1. Add `initializer: ?ast.Expr` (or a pre-folded constant handle) to `ir.Global`.
2. In AST→IR lowering, when a global is `const` (or has an initializer), carry the
   init expression.
3. In `emitGlobals`, if present: fold it to a SPIR-V constant id (reuse the
   existing constant-composite emitter the local-array path already uses), emit
   the `OpVariable` with word-count **5** and the constant id as the initializer.
   Private+initializer is valid SPIR-V (`spirv-val` clean) and Vulkan-legal.
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
