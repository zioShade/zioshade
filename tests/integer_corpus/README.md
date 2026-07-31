# Integer / quantized-output corpus — the UB-free contract

This corpus is zioshade's **airtight** correctness claim: a set of shaders whose
output is floating-point-ordering-independent, so any cross-backend render DIFFER
is a *guaranteed* real compiler bug. Floating-point chaos cannot contaminate it.
This is the Csmith move (randomized differential testing of compilers via
defined-behavior-only programs) applied to shaders.

Run it: `just prove-integer` (renders MSL direct + GLSL + WGSL, all must MATCH).

## The contract

**Every shader in this directory is constructed to contain no SPIR-V undefined
behavior.** Therefore a render disagreement between two backends (or vs an
independent compiler) can only be a miscompilation — never an artifact of UB or
FP nondeterminism. The contract is what makes `any DIFFER == bug` airtight.

### What IS undefined behavior in SPIR-V (and is therefore forbidden here)

| Construct | Why it is UB |
|---|---|
| **Integer division/modulo by zero** (`OpSDiv`/`OpUDiv`/`OpSMod`/`OpUMod`/`OpSRem` with a zero divisor) | Result is undefined; two correct backends may diverge |
| **`OpSDiv` / `OpSMod` / `OpSRem` of `INT_MIN` by `-1`** | Signed-division overflow; the one signed-int "overflow" that is genuinely UB in SPIR-V |
| **Out-of-bounds access** (`OpAccessChain`/`OpVectorExtractDynamic`/`OpPtrAccessChain` beyond the composite bounds) | Undefined result value |
| **Reading an uninitialized value** (load of a `Function` `OpVariable` before any store, or any use of `OpUndef`) | Undefined value |
| **Reading `gl_FragCoord`/builtins outside the framebuffer** | n/a for fragment here; the harness only invokes covered pixels |

### What is NOT UB in SPIR-V (and is therefore allowed here)

- **Integer add / subtract / multiply wrap in two's complement (modulo 2^N).**
  This is *defined* behavior in SPIR-V, **not** undefined. So `collatz` (`3*n+1`),
  `fib_mod`, `int_product` (factorial), and `nested_int_loop` may wrap and still
  satisfy the contract — all backends wrap identically. (This corrects the common
  C-trained intuition that "integer overflow is UB"; in SPIR-V shaders it is not,
  except the signed-division case above.) `NoSignedWrap`/`NoUnsignedWrap`
  decorations would make wrapping UB; `tools/integer_corpus_ub_check.sh` now FAILS if
  any such decoration is present, so a future frontend change adding them cannot
  silently invalidate the contract.
- **Metal/C++ signed-overflow caveat (render layer).** SPIR-V defines integer wrap,
  but MSL is C++-derived and signed overflow is technically UB at the *language* layer.
  The render-equality claim therefore holds *differentially* -- on Apple GPU hardware
  that wraps deterministically, which is the regime this corpus targets. The curated
  metamorphic pairs use non-overflowing ranges (e.g. `x` in [0,31] for `x*8`), so the
  metamorphic oracle never relies on this; only the few corpus shaders that can
  overflow (`collatz`, `fib_mod`, `int_product`) lean on identical hardware wrap
  across backends on the same device.
- **`OpFMod` / `OpFRem` with a nonzero divisor** — defined (this is float, not int).
- **Shifts by a count < the operand width** — defined. (Shift >= width would be UB;
  every shift here is bounded: `i < 16` for 32-bit, etc.)

## Enforcement

Two checks keep the contract honest; both must stay green:

1. **`tools/integer_corpus_ub_check.sh`** — compiles every `.frag` under
   `tests/integer_corpus/` (top-level **and** the `metamorphic/` pair members) to
   SPIR-V and statically asserts the machine-checkable invariants: no `OpUndef`, no
   integer div/mod whose divisor resolves to constant 0 or `INT_MIN/-1`, and no
   `NoSignedWrap`/`NoUnsignedWrap` decoration. Run: `just ub-check` (exit nonzero on
   any violation).
2. **Manual review at add-time** for the classes a static check cannot fully
   decide: out-of-bounds dynamic indexing and uninitialized-variable reads that do
   not go through `OpUndef`. The per-shader table below is that review, recorded.

## Per-shader compliance

| Shader | Arithmetic that could look risky | Why it is UB-free |
|---|---|---|
| `bit_count` | `float(c)/16.0` | FP divisor; int path is shifts by `i<16` (no div/mod) |
| `collatz` | `3*n+1` may overflow | int mul/add **wrap = defined**; loop bounded `steps<1000`; no div/mod |
| `comparisons` | none | pure relational + ternary |
| `fib_mod` | `(a+b) & 1023`, name says "mod" | bitwise AND mask, not `Op*Mod`; add wraps = defined; loop `i<n≤32` |
| `gcd` | `a % b` (Euclid) | divisor `b` is guaranteed `!= 0` by the `while (b != 0)` guard; operands in `[1,32]`, no `INT_MIN/-1` |
| `int_grid` | shifts/xor | shift counts `< 32`; no div/mod |
| `int_product` | `p *= i` factorial overflow | int mul **wraps = defined**; `n∈[1,8]` (no overflow anyway) |
| `int_sum` | `s += i` triangular | add wraps = defined; tiny range |
| `int_switch` | switch fallthrough | `col` initialized `vec3(0.0)`; integer selector only |
| `nested_int_loop` | `i*j`, `total +=` | mul/add wrap = defined; small bounded loops |
| `parity` | shifts/xor | shift counts `< 16`; no div/mod |
| `step_bands` | `int(x) / 32` | divisor is constant `32 != 0`; not `-1`, so no `INT_MIN/-1` |

### Metamorphic pairs (`metamorphic/*.frag`)

The 10 shaders in `metamorphic/` (5 equivalent pairs exercised by `just metamorphic`)
are UB-free by construction: no division/modulo (so no div-by-zero), no `OpUndef`, and
non-overflowing integer ranges (`x` in [0,31] for `mulshift`'s `x*8`, etc.). They are
covered by `just ub-check` (recursive), so the oracle's "DIFFER = guaranteed bug"
claim holds for both members of every pair.

When adding a shader to this corpus, add a row here and confirm both enforcement
checks pass. A shader that needs division must use a constant-nonzero divisor or
guard the divisor to nonzero before the divide.
