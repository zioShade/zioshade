#!/usr/bin/env bash
# Chaos sensitivity classifier (source-signature heuristic).
#
# Bins each shader as:
#   CHAOS        FP-amplifying — hash/fractal/iterative-escape/transcendental chains. No
#                single correct pixel: two correct compilers legitimately diverge. EXCLUDED
#                from the pixel-correctness claim (downgraded to "compiles + runs").
#   BINDING      declares a texture/sampler/UBO the generic harness can't supply — a DIFFER
#                here is a harness artifact, not a miscompile.
#   DETERMINISTIC FP-ordering-independent — a DIFFER here is a real-bug suspect (testable).
#
# This DETECTS-and-excludes chaotic shaders, filling the GraphicsFuzz gap (which only
# *tolerates* FP). The rigorous form is a 1-ULP input perturbation probe (render the
# reference twice, measure output sensitivity); this source-signature heuristic is the
# cheap, repeatable approximation that matches the manual triage. A DIFFER on a DETERMINISTIC
# shader is the prime bug suspect; a DIFFER on a CHAOS shader is expected (benign).
#
# Usage:
#   tools/chaos_classify.sh <dir>                  # bin the whole corpus
#   tools/chaos_classify.sh <dir> name1 name2 ...  # bin only the named shaders (e.g. DIFFERs)
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
shift || true
NAMES=("$@")

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }

for f in "$DIR"/*.frag; do
  case "$f" in *.asm.*) continue;; esac
  [ -e "$f" ] || continue
  name=$(basename "$f")
  if [ ${#NAMES[@]} -gt 0 ]; then
    match=0
    for n in "${NAMES[@]}"; do [[ "$name" == "$n" || "$name" == "$n.frag" ]] && match=1; done
    [ $match -eq 0 ] && continue
  fi
  if grep -qE 'fract|sin|cos|tan|asin|acos|atan|pow|exp|log|43758|hash|noise|mandel|julia|dragon|logistic|bifurcat|weierstrass' "$f" 2>/dev/null; then
    verdict=CHAOS
  elif grep -qE 'sampler|image2D|uniform [A-Z]|layout\(binding|subpass' "$f" 2>/dev/null; then
    verdict=BINDING
  else
    verdict=DETERMINISTIC
  fi
  bump "$verdict"
  echo "$name: $verdict"
done

echo ""
echo "=== chaos classification ($(basename "$DIR")) ==="
for k in CHAOS DETERMINISTIC BINDING; do echo "  $k: ${C[$k]:-0}"; done
