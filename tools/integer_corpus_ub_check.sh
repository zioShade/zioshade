#!/usr/bin/env bash
# zioshade - integer-corpus UB-free contract guard (r2d.4)
#
# Machine-checks the UB-free contract documented in tests/integer_corpus/README.md
# for the classes that are statically decidable:
#   * no OpUndef present anywhere (uninitialized-value source)
#   * no INTEGER division/modulo (OpSDiv/OpUDiv/OpSMod/OpUMod/OpSRem) whose divisor
#     resolves to the constant 0, and no OpS(Div|Mod|Rem) of INT_MIN by -1
# Variable divisors (e.g. gcd's Euclid loop, guaranteed nonzero by a runtime guard)
# are printed as INFO and point to the README's manual-review table -- they are NOT
# failures, because "divisor is provably nonzero at runtime" is not statically decidable.
#
# Float OpFDiv/OpFMod/OpFRem by 0.0 yield Inf/NaN (IEEE, defined) and are intentionally
# NOT checked -- that is not UB. Integer add/mul/sub wrap (defined) and need no check.
#
# Exit nonzero on any FAIL. Run: bash tools/integer_corpus_ub_check.sh
set -euo pipefail
export LC_ALL=C
export PATH="$HOME/.local/share/mise/shims:$PATH"
cd "$(dirname "$0")/.."

CLI=zig-out/bin/zioshade
if [ ! -x "$CLI" ]; then
  echo "building CLI (zig build cli)..." >&2
  mise exec -- zig build cli
fi

INTMIN="-2147483648"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
fails=0

for src in tests/integer_corpus/*.frag; do
  if ! "$CLI" compile "$src" -o "$TMP" 2>/dev/null; then
    echo "FAIL $(basename "$src"): compile failed"; fails=$((fails+1)); continue
  fi
  dis=$(spirv-dis "$TMP" 2>/dev/null) || { echo "FAIL $(basename "$src"): spirv-dis failed"; fails=$((fails+1)); continue; }

  # One awk pass: build OpConstant id->value map, then check integer div/mod + OpUndef.
  # awk prints FAIL/INFO lines directly; its exit code (1 only on a real FAIL) drives the count.
  if ! printf '%s\n' "$dis" | awk -v SHADER="$(basename "$src")" -v INTMIN="$INTMIN" '
    function strip(s){ sub(/^%/,"",s); return s }
    # OpConstant (plain or %id = assign form); trailing-space anchor excludes Composite/Null/Bool
    /^[[:space:]]*OpConstant /                  { id=strip($3); val=$4;   constv[id]=val }
    /^[[:space:]]*%[A-Za-z0-9_]+ = OpConstant / { id=strip($1); val=$NF;  constv[id]=val }
    {
      op = ($2 == "=") ? $3 : $1
      if (op == "OpSDiv" || op == "OpUDiv" || op == "OpSMod" || op == "OpUMod" || op == "OpSRem") {
        divisor_id  = strip($NF); dividend_id = strip($(NF-1))
        if (divisor_id in constv) {
          dv = constv[divisor_id]
          if (dv == "0") { print "FAIL " SHADER ": " op " by ZERO constant: " $0; bad=1 }
          if ((op == "OpSDiv" || op == "OpSMod" || op == "OpSRem") && (dividend_id in constv) && (constv[dividend_id]==INTMIN) && (dv=="-1")) {
            print "FAIL " SHADER ": " op " INT_MIN/-1: " $0; bad=1 }
        } else {
          print "INFO " SHADER ": " op " variable divisor (confirm runtime-guarded; see tests/integer_corpus/README.md): " $0
        }
      }
    }
    /^[[:space:]]*OpUndef/ || /^[[:space:]]*%[A-Za-z0-9_]+ = OpUndef/ { print "FAIL " SHADER ": OpUndef present: " $0; bad=1 }
    END { exit (bad ? 1 : 0) }
  '; then
    fails=$((fails+1))
  fi
done

echo ""
if [ "$fails" -ne 0 ]; then
  echo "UB contract guard: $fails shader(s) FAILED"; exit 1
fi
echo "UB contract guard: PASS (no OpUndef; no integer div/mod by constant 0 or INT_MIN/-1; variable divisors INFO'd above)"
