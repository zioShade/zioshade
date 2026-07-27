#!/usr/bin/env bash
# 3-oracle MSL majority vote (ground-truth classification of a DIFFER).
#
# A naga DIFFER (zioshade vs naga) has no ground truth at N=2. Add spirv-cross as a
# third oracle: render zioshade-MSL, spirv-cross-MSL, and naga-MSL on Metal and let the
# majority rule (ICSE-2016 RDT — the strongest compiler-correctness oracle).
#
# Pairs available without new infra:
#   z vs spirv-cross : ShaderCompare  (both spirv-cross-style main0 MSL)
#   z vs naga        : NagaCompare    (naga's main_ entry struct)
# spirv-cross is the render-proven reference, so "z agrees with spirv-cross" is the
# decisive fact: z is then correct and naga is the outlier (or chaos). Each pair is
# FP-adjudicated (precise-FP re-render): EDGE = benign fast-math contraction.
#
# Classification:
#   AGREE-ALL          z==sc && z==n            (3-way agreement)
#   NAGA-OUTLIER       z==sc && z!=n            (z agrees with the reference; naga dissents)
#   SC-OUTLIER         z!=sc && z==n            (z agrees with naga; spirv-cross dissents)
#   Z-DISAGREES-BOTH   z!=sc && z!=n            (chaos, or a real zioshade bug — chaos-probe target)
#
# Usage: tools/prove_3oracle.sh <frag> [<frag>...]   or   tools/prove_3oracle.sh --dir <path>
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_3oracle}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
NC=$SHARE/NagaCompare
[ -x "$SC" ] || swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc (ShaderCompare) failed"; exit 2; }
[ -x "$NC" ] || swiftc -O tools/NagaCompare.swift -o "$NC" 2>/dev/null || { echo "error: swiftc (NagaCompare) failed"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

# Echo MATCH / EDGE / DIFFER for a pair via the given harness binary.
pair_verdict() {
  local bin="$1" a="$2" b="$3" tag="$4"
  local o os
  o=$("$bin" "$a" "$b" "${SHARE}/${tag}" 2>&1)
  if printf '%s' "$o" | grep -q 'MATCH'; then echo "MATCH"; return; fi
  if printf '%s' "$o" | grep -q 'DIFFER'; then
    # FP adjudication: re-render precise. MATCH => benign contraction (EDGE).
    os=$(SHADERCOMPARE_SAFE_MATH=1 "$bin" "$a" "$b" "${SHARE}/${tag}_p" 2>&1)
    if printf '%s' "$os" | grep -q 'MATCH'; then echo "EDGE"; else echo "DIFFER"; fi
    return
  fi
  echo "SKIP"
}

vote_one() {
  local frag="$1" name; name=$(basename "$frag" .frag)
  local d="$SHARE/$name"
  sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$frag" > "$d.g.frag"
  glslangValidator -V -S frag "$d.g.frag" -o "$d.spv" >/dev/null 2>&1 || { echo "skip-glslang"; return; }
  "$CLI" msl "$d.spv" --stage fragment > "$d.z.msl" 2>/dev/null || { echo "skip-zmsl"; return; }
  spirv-cross --msl "$d.spv" > "$d.sc.msl" 2>/dev/null || { echo "skip-scmsl"; return; }
  naga "$d.spv" "$d.n.metal" 2>/dev/null || { echo "skip-naga"; return; }

  local z_sc z_n
  z_sc=$(pair_verdict "$SC" "$d.z.msl" "$d.sc.msl" "${name}_zsc")
  z_n=$(pair_verdict "$NC" "$d.z.msl" "$d.n.metal" "${name}_zn")

  local zeq_sc=0 zeq_n=0
  [[ "$z_sc" == MATCH || "$z_sc" == EDGE ]] && zeq_sc=1
  [[ "$z_n" == MATCH || "$z_n" == EDGE ]] && zeq_n=1

  if [[ $zeq_sc -eq 1 && $zeq_n -eq 1 ]]; then echo "AGREE-ALL (z==sc:$z_sc z==n:$z_n)"; return; fi
  if [[ $zeq_sc -eq 1 && $zeq_n -eq 0 ]]; then echo "NAGA-OUTLIER (z==sc:$z_sc, naga dissents:$z_n)"; return; fi
  if [[ $zeq_sc -eq 0 && $zeq_n -eq 1 ]]; then echo "SC-OUTLIER (spirv-cross dissents:$z_sc, z==n:$z_n)"; return; fi
  echo "Z-DISAGREES-BOTH (z!=sc:$z_sc z!=n:$z_n — chaos-probe target)"
}

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }

if [ "${1:-}" = "--dir" ]; then
  for f in "${2:?usage: --dir <path>}"/*.frag; do
    [ -e "$f" ] || continue; case "$f" in *.asm.*) continue;; esac
    v=$(vote_one "$f"); bump "${v%% *}"; echo "$(basename "$f" .frag).frag: $v"
  done
else
  [ $# -ge 1 ] || { echo "Usage: tools/prove_3oracle.sh <frag>... | --dir <path>"; exit 1; }
  for f in "$@"; do
    [ -e "$f" ] || { echo "$f: not found"; continue; }
    v=$(vote_one "$f"); bump "${v%% *}"; echo "$(basename "$f" .frag).frag: $v"
  done
fi

echo ""
echo "=== 3-oracle vote ==="
for k in "AGREE-ALL" "NAGA-OUTLIER" "SC-OUTLIER" "Z-DISAGREES-BOTH" skip-glslang skip-zmsl skip-scmsl skip-naga SKIP; do
  echo "  $k: ${C[$k]:-0}"
done
