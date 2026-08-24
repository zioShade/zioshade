#!/usr/bin/env bash
# GLSL faithfulness SWEEP — the value-level silent-wrong detector.
#
# Runs tools/glsl_faithfulness.sh over every pure-gl_FragCoord fragment in
# tests/spirv-cross (no uniform/texture/sampler/buffer declarations — the subset
# where the render-proxy is artifact-free; uniform-bound shaders read unbound
# garbage in NagaCompare and false-UNFAITHFUL). A single UNFAITHFUL hit here is
# a REAL zioshade-GLSL emission bug that compiles clean: the construct-count
# gates (structural-drop) cannot see wrong VALUES, only missing constructs.
# This sweep found #switch-break-vs-default-target (PR #596) after every
# compile-only gate and the structural-drop sweep had passed.
#
# ARTIFACT CLASS 2 (uninitialized reads): a shader that READS an uninitialized
# local (e.g. only some array elements assigned, then a dynamic index into it)
# has undefined values, and the two renders may legitimately differ. The
# conformance/stress corpus triage (2026-08-13): both UNFAITHFUL hits were this
# (array_size_literal_led, const_expr_array_size) — confirmed by initializing
# every element in a copy and re-running (both flipped to FAITHFUL).
# DISCRIMINATOR: initialize all reads in a copy; FAITHFUL => UB artifact,
# UNFAITHFUL => real bug.
# NOW AUTO-SKIPPED: tools/glsl_faithfulness.sh runs tools/spv_undef_read.py on
# the assembled source SPIR-V (the same conservative class the render gates
# skip on) and reports skip-undef-read, counted below; a miss stays a loud
# UNFAITHFUL and still needs the manual discriminator above.
#
#
# ARTIFACT CLASS 4 (undefined-math domain at zero varyings): the harness feeds
# ZERO varyings, so a shader whose math lands on an implementation-defined point
# (pow(0,0), log(0), 1/0...) diverges legitimately (exp-log-pow.frag: uv=0 ->
# pow(0,0), which backends may define differently even under safe math).
# DISCRIMINATOR: perturb the inputs off the undefined point in a copy (e.g.
# + 0.5); FAITHFUL => artifact, UNFAITHFUL => real bug.
#
# FULL-CORPUS VERDICT (2026-08-13, post-#596/#601): 1247 shaders incl.
# uniform-bound, 1140 FAITHFUL, 2 UNFAITHFUL both triaged as artifacts (one
# class 2, one class 4) => the entire spirv-cross fragment corpus is clean of
# real value silent-wrongs under the 2-oracle render differential.
#
# Usage: tools/glsl_faithful_sweep.sh [dir]     (default tests/spirv-cross)
# Exit 0 always — read the tallies; triage UNFAITHFUL lines by hand.
set -uo pipefail
cd "$(dirname "$0")/.."

DIR=${1:-tests/spirv-cross}
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
for f in "$DIR"/*.frag; do
  grep -qE '^[[:space:]]*(uniform|texture|sampler|buffer)' "$f" && continue
  # ARTIFACT CLASS 3 (no output): a shader with no `out` declaration renders
  # nothing defined, so the pixel comparison is garbage-vs-garbage (minimal_test.frag
  # false-UNFAITHFUL; adding an output flips it to FAITHFUL). Skip them.
  grep -qE '^[[:space:]]*(layout\([^)]*\)[[:space:]]+)?out[[:space:]]+[a-zA-Z]' "$f" || continue
  echo "$f"
done > "$LIST"

declare -A C
bump() { C[$1]=$((${C[$1]:-0}+1)); }
total=0; unfaith=0
while IFS= read -r f; do
  v=$(tools/glsl_faithfulness.sh "$f" 2>/dev/null | grep -E '\.frag: ' | head -1 | sed 's/.*: //')
  [ -z "$v" ] && v=skip-nooutput
  bump "$v"; total=$((total+1))
  case "$v" in
    UNFAITHFUL*) unfaith=$((unfaith+1)); echo "UNFAITHFUL: $f" ;;
  esac
done < "$LIST"

echo ""
echo "=== GLSL faithfulness sweep ($DIR, pure-gl_FragCoord only) ==="
for k in FAITHFUL "FAITHFUL(edge)" "UNFAITHFUL(real GLSL bug)" skip-glslang skip-zglsl skip-zglslang skip-naga skip-render skip-nooutput skip-undef-read; do
  echo "  $k: ${C[$k]:-0}"
done
echo "  total: $total"
[ "$unfaith" -eq 0 ] && echo "CLEAN: no value silent-wrongs in this subset." \
                      || echo "TRIAGE: $unfaith UNFAITHFUL hit(s) above."
