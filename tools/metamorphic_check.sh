#!/usr/bin/env bash
# zioshade - metamorphic equivalence oracle (r2d.5, pass 1: curated pairs)
#
# spirv-fuzz-style metamorphic testing, narrowed to the FP-chaos-free integer domain.
# For each pair (name.frag, name.meta.frag) of PROVABLY-equivalent GLSL programs in
# tests/integer_corpus/metamorphic/, cross-compile BOTH with zioshade's MSL backend and
# render-diff them on Metal. The two must render identically: the rewrite preserves
# integer semantics, and integer arithmetic wraps (defined), so there is no FP/UB slack.
#
# A DIFFER is therefore a GUARANTEED zioshade miscompilation -- the operand-level class
# that differential-testing ACROSS compilers cannot reach (zioshade and a reference each
# accept both programs separately, yet disagree across the equivalent pair). This is the
# one gap the maturity assessment flagged as uncovered by the 3-oracle + render-diff stack.
#
# FAILS CLOSED: a miscompilation detector must never silently pass. If the render harness
# breaks (Metal-compile crash, junk/unrecognized ShaderCompare output) or zero pairs
# render, this script exits nonzero -- it never reports "metamorphic-stable" on no
# evidence. (A previous form counted any unrecognized output as a skip and still PASSED.)
#
# Pair-equivalence is human-authored (each rewrite is a law of wrapping-integer
# arithmetic: identity, reassociation, two's complement, mul==shift, dead code).
# Auto-generation (spirv-fuzz style) is pass 2. A non-equivalent pair would be a false
# positive, so rewrites are kept minimal and obviously-correct.
#
# Exit nonzero on any DIFFER or harness failure. Run: bash tools/metamorphic_check.sh
set -euo pipefail
export LC_ALL=C
export PATH="$HOME/.local/share/mise/shims:$PATH"
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_metamorphic}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed (needs macOS/Metal)"; exit 2; }
[ -x "$CLI" ] || { echo "building CLI (zig build cli)..."; mise exec -- zig build cli; }

bump() { C[$1]=$(( ${C[$1]:-0} + 1 )); }   # helper: increment a counter (set -u safe via :-)
declare -A C
for orig in tests/integer_corpus/metamorphic/*.frag; do
  case "$orig" in *.meta.frag) continue;; esac
  name=$(basename "$orig" .frag)
  meta="tests/integer_corpus/metamorphic/$name.meta.frag"
  [ -f "$meta" ] || { echo "$name: no .meta.frag pair -- skipping"; continue; }

  if ! "$CLI" msl "$orig" -o "$SHARE/$name.msl" 2>/dev/null; then
    echo "$name: FAIL -- zioshade msl rejected the ORIGINAL"; bump fail; continue; fi
  if ! "$CLI" msl "$meta" -o "$SHARE/$name.meta.msl" 2>/dev/null; then
    echo "$name: FAIL -- zioshade msl rejected the VARIANT"; bump fail; continue; fi

  # FAIL CLOSED: capture ShaderCompare's exit; any nonzero or unrecognized output is a
  # harness failure, NOT a skip. (Otherwise a broken Metal compile turns the oracle into
  # a rubber stamp that PASSes on zero evidence.)
  set +e
  o=$("$SC" "$SHARE/$name.msl" "$SHARE/$name.meta.msl" "$SHARE/$name" 2>&1); rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "$name: HARNESS_FAIL (ShaderCompare exit $rc -- Metal compile/render crash; not a clean render)"; bump harness_fail; continue; fi
  if   printf '%s' "$o" | grep -q '^MATCH'; then
    echo "$name: MATCH (metamorphic-stable)"; bump match
  elif printf '%s' "$o" | grep -q 'SKIP(harness-binding)'; then
    echo "$name: skip(harness-binding)"; bump skip
  elif printf '%s' "$o" | grep -qE '^DIFFER'; then
    md=$(printf '%s' "$o" | grep -oE 'max diff: [0-9]+' | grep -oE '[0-9]+$')
    echo "$name: *** DIFFER (maxdiff=${md:-?}) -- zioshade miscompiles an equivalent pair (real bug) ***"
    bump differ
  else
    echo "$name: HARNESS_FAIL (unrecognized ShaderCompare output -- not MATCH/DIFFER/SKIP)"; bump harness_fail
  fi
done

echo ""
echo "metamorphic oracle (r2d.5 pass 1):"
for k in match differ skip fail harness_fail; do [ -n "${C[$k]:-}" ] && printf "  %-13s %s\n" "$k" "${C[$k]}"; done

if [ -n "${C[differ]:-}" ];       then echo "FAIL: ${C[differ]} metamorphic DIFFER(s) -- investigate"; exit 1; fi
if [ -n "${C[fail]:-}" ];         then echo "FAIL: ${C[fail]} compile failure(s)"; exit 1; fi
if [ -n "${C[harness_fail]:-}" ]; then echo "FAIL: ${C[harness_fail]} harness failure(s) -- oracle did not render cleanly (fails closed)"; exit 1; fi
if [ -z "${C[match]:-}" ];        then echo "FAIL: zero pairs rendered MATCH -- render harness is broken (fails closed)"; exit 1; fi
echo "PASS: all ${C[match]} equivalent pair(s) rendered identically (metamorphic-stable)"
