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
#   none             no gate wired (would be a loud gap, not a silent pass)
#
# Run:  just prove-all                  # run every gate (slow; uses Metal/GPU)
#       bash tools/prove_all.sh --list  # print the plan without running gates
#       bash tools/prove_all.sh         # same as just prove-all
set -uo pipefail
cd "$(dirname "$0")/.."

LIST=0
[ "${1:-}" = "--list" ] && LIST=1

# Each row: confidence|backend|gate-label|command…
# Fragment stage is the primary surface; the *-all `just` recipes add vertex+compute.
GATES=(
  "render-proven|MSL  |MSL render, unoptimized (1/25 sample; PROVE_FULL=1 for whole corpus)|bash tools/prove.sh"
  "render-proven|MSL  |MSL render, spirv-opt -O (optimized)|bash tools/prove_opt.sh --sweep"
  "compile-verified|MSL |MSL Metal-compile (fragment)|bash tools/msl_validity_sweep.sh tests/spirv-cross fragment frag"
  "compile-verified|GLSL|GLSL glslang-compile (fragment)|bash tools/glsl_glslang_sweep.sh tests/spirv-cross fragment frag"
  "compile-verified|WGSL|WGSL naga-compile (conformance corpus)|bash tools/wgsl_naga_sweep.sh"
  "compile-verified|HLSL|HLSL glslang-compile (fragment)|bash tools/hlsl_glslang_sweep.sh tests/spirv-cross fragment frag"
)

if [ "$LIST" = "1" ]; then
  echo "# prove-all plan (gates NOT run):"
  for row in "${GATES[@]}"; do
    IFS='|' read -r conf backend label cmd <<<"$row"
    printf '  [%s] %-5s %s\n    -> %s\n' "$conf" "$backend" "$label" "$cmd"
  done
  exit 0
fi

echo "Running every backend differential/validity gate …" >&2
declare -a RESULTS
FAIL=0
for row in "${GATES[@]}"; do
  IFS='|' read -r conf backend label cmd <<<"$row"
  printf '  • %-5s %s …\r' "$backend" "$label" >&2
  # shellcheck disable=SC2086
  if eval "$cmd" >/tmp/zs_prove_all.out 2>&1; then
    RESULTS+=("$conf|$backend|$label|PASS")
  else
    rc=$?
    RESULTS+=("$conf|$backend|$label|FAIL(rc=$rc)")
    FAIL=1
    echo "    … FAILED (rc=$rc); tail:" >&2
    tail -n 6 /tmp/zs_prove_all.out | sed 's/^/      /' >&2
  fi
done

cat <<MD

## zioshade differential — per-backend confidence

| Backend | Confidence       | Gate                              | Result |
|---------|------------------|-----------------------------------|--------|
MD
for r in "${RESULTS[@]}"; do
  IFS='|' read -r conf backend label result <<<"$r"
  printf '| %s | %s | %s | %s |\n' "$backend" "$conf" "$label" "$result"
done
cat <<'MD'

**render-proven** = output run on a real GPU and diffed vs an independent
reference (semantic proof). **compile-verified** = a validator accepts the
output (well-formedness only; cannot catch plausible-but-wrong). See
docs/DIFFERENTIAL_PROOF.md for the per-backend confidence taxonomy.
MD

exit "$FAIL"
