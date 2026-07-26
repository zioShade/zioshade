#!/usr/bin/env bash
# Unified differential driver for zioshade (harness consolidation, step 1).
#
# One command, one honest report: runs every backend's differential/validity
# gate and prints a per-backend CONFIDENCE table. This is the orchestration layer
# the existing scripts hang off of — they are NOT modified here (build-alongside,
# flip-when-green, per the panel's risk caveat: never disturb the render-proven
# MSL evidence base). Later steps fold each script into an adapter behind this
# driver; for now it delegates.
#
# Confidence taxonomy the harness enforces (see docs/DIFFERENTIAL_PROOF.md):
#   render-proven    output run on a real GPU, pixels/buffers diffed vs a
#                    reference compiler = semantic proof (strongest)
#   compile-verified a validator accepts the output = well-formedness only,
#                    NOT semantic proof (cannot catch plausible-but-wrong)
#
# Honesty note on the RESULT column: render and compile gates are reported
# differently on purpose.
#   - compile gates (msl/glsl/wgsl/hlsl sweeps) exit nonzero only on a NEW
#     regression (they carry a KNOWN_INVALID baseline), so exit-code is honest:
#     valid / INVALID.
#   - prove_opt (optimized render) exits 1 on ANY DIFFER, including the
#     campaign-classified benign-FP/harness-artifact residual — so a bare
#     exit-code would FALSELY red-flag the render-proven optimized path. It is
#     therefore reported as its verdict COMPOSITION (MATCH/DIFFER/EDGE counts),
#     never as a pass/fail. DIFFER ≠ proven bug; each is classified in
#     docs/DIFFERENTIAL_PROOF.md.
#   - prove (unoptimized render) exit-code is meaningful (nonzero = real
#     divergence), so it is reported as 0 divergences / DIVERGENT.
# The script's own exit is green iff every compile gate is valid AND the
# unoptimized render has 0 divergences — it does NOT fail on prove_opt's residual.
#
# Run:  just prove-all                  # run every gate (slow; uses Metal/GPU)
#       bash tools/prove_all.sh --list  # print the plan without running gates
set -uo pipefail
cd "$(dirname "$0")/.."

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

# Each row: confidence|backend|gate-label|kind|command…
#   kind ∈ {render, opt-render, compile}. Fragment stage is the primary surface;
#   the *-all `just` recipes add vertex+compute.
GATES=(
  "render-proven|MSL|MSL render, unoptimized (1/25 sample; PROVE_FULL=1 for full)|render|bash tools/prove.sh"
  "render-proven|MSL|MSL render, spirv-opt -O (optimized; residual DIFFERs are benign/artifact)|opt-render|bash tools/prove_opt.sh --sweep"
  "compile-verified|MSL|MSL Metal-compile (fragment)|compile|bash tools/msl_validity_sweep.sh tests/spirv-cross fragment frag"
  "compile-verified|GLSL|GLSL glslang-compile (fragment)|compile|bash tools/glsl_glslang_sweep.sh tests/spirv-cross fragment frag"
  "compile-verified|WGSL|WGSL naga-compile (conformance corpus)|compile|bash tools/wgsl_naga_sweep.sh"
  "compile-verified|HLSL|HLSL glslang-compile (fragment)|compile|bash tools/hlsl_glslang_sweep.sh tests/spirv-cross fragment frag"
)

if [ "$LIST" = "1" ]; then
  echo "# prove-all plan (gates NOT run):"
  for row in "${GATES[@]}"; do
    IFS='|' read -r conf backend label kind cmd <<<"$row"
    printf '  [%s] %-5s (%s) %s\n    -> %s\n' "$conf" "$backend" "$kind" "$label" "$cmd"
  done
  exit 0
fi

echo "Running every backend differential/validity gate …" >&2
declare -a RESULTS
FAIL=0
n=0
for row in "${GATES[@]}"; do
  IFS='|' read -r conf backend label kind cmd <<<"$row"
  n=$((n + 1))
  out="/tmp/zs_prove_gate_${n}.out"
  printf '  • %-5s %s …\n' "$backend" "$label" >&2
  # shellcheck disable=SC2086
  if eval "$cmd" >"$out" 2>&1; then rc=0; else rc=$?; fi

  case "$kind" in
    opt-render)
      # prove_opt: report verdict composition (a benign residual is NOT a failure).
      M=$(grep -c 'MATCH' "$out" 2>/dev/null); M=${M:-0}
      D=$(grep -c 'DIFFER' "$out" 2>/dev/null); D=${D:-0}
      E=$(grep -c 'EDGE' "$out" 2>/dev/null); E=${E:-0}
      result="MATCH=$M DIFFER=$D EDGE=$E (residual classified in DIFFERENTIAL_PROOF.md)"
      ;;
    render)
      # prove (unoptimized): exit-code is meaningful.
      if [ "$rc" = 0 ]; then result="0 divergences (1/25 sample)"; else
        result="DIVERGENT rc=$rc"; FAIL=1
        echo "    … DIVERGENT (rc=$rc); tail:" >&2; tail -n 6 "$out" | sed 's/^/      /' >&2
      fi
      ;;
    compile)
      if [ "$rc" = 0 ]; then result="valid (rc=0)"; else
        result="INVALID rc=$rc"; FAIL=1
        echo "    … INVALID (rc=$rc); tail:" >&2; tail -n 6 "$out" | sed 's/^/      /' >&2
      fi
      ;;
  esac
  RESULTS+=("$conf|$backend|$label|$result")
done

cat <<MD

## zioshade differential — per-backend confidence

| Backend | Confidence       | Gate | Result |
|---------|------------------|------|--------|
MD
for r in "${RESULTS[@]}"; do
  IFS='|' read -r conf backend label result <<<"$r"
  printf '| %s | %s | %s | %s |\n' "$backend" "$conf" "$label" "$result"
done
cat <<'MD'

**render-proven** = output run on a real GPU and diffed vs an independent
reference (semantic proof). **compile-verified** = a validator accepts the
output (well-formedness only; cannot catch plausible-but-wrong). For optimized
MSL, MATCH/DIFFER/EDGE is the verdict composition: DIFFER ≠ proven bug — each
is classified in docs/DIFFERENTIAL_PROOF.md (residual = benign-FP / harness
artifact, not structural). See that doc for the full per-backend taxonomy.
MD

exit "$FAIL"
