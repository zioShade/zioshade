#!/usr/bin/env bash
# WebGPU CTS (webgpu:shader) ingestion credibility sweep (r2d.1). The last
# unmeasured leg of the 2026-07-31 maturity assessment ("no Khronos/WebGPU CTS
# pass"): what fraction of WebGPU CTS shader cases can zioshade's SPIR-V ->
# WGSL backend ingest and lower to valid WGSL?
#
# DIRECTION (the design decision this harness stands on): the WebGPU CTS
# webgpu:shader tests are written IN WGSL and compiled by the implementation
# under test; zioshade is a SPIR-V -> WGSL cross-compiler and does not ingest
# WGSL at all, so CTS .wgsl cannot be fed to it directly. The roadmap's
# alternative (Vulkan CTS spirv_assembly) is inline asm inside dEQP C++
# programs, not a .spv corpus (established in r2d.2, tools/cts_ingestion_sweep.sh).
# So this harness runs the CTS corpus through the one available round trip:
#
#   CTS WGSL --naga--> SPIR-V --zioshade--> WGSL --naga--> verdict
#
# i.e. the CTS's own WGSL, converted to SPIR-V by naga (the same oracle the
# WGSL gates use), cross-compiled back to WGSL by zioshade, and validated by
# naga again. When a tint CLI is available (env TINT, else `tint` on PATH; the
# upstream converter at ~/.local/bin/tint is dawn 5e9e5136 built with
# TINT_BUILD_WGSL_READER+SPV_WRITER), naga-refused cases get a SECOND chance
# through `tint --format spirv`: the subgroups-enabled WGSL that dominates the
# naga-refused class converts fine with tint. upstream-convert-failed then
# means BOTH converters refused. A tint-converted case flows through the SAME
# zioshade + naga-validate legs (no greenwashing: tint widens the measurable
# denominator, it never blesses output). Without tint the sweep is naga-only,
# exactly the pre-tint behavior. Per case this classifies:
#   roundtrip-valid          every leg succeeded: zioshade ingested + lowered
#                            the CTS shader to WGSL that naga accepts.
#   upstream-convert-failed  naga refused WGSL -> SPIR-V (feature-gated WGSL
#                            the local naga lacks, or corpus rot). NOT counted
#                            against zioshade.
#   zioshade-refused         zioshade exited nonzero with a diagnostic (honest
#                            error). Counted in the denominator.
#   zioshade-invalid         zioshade exited 0 but naga rejects the output
#                            (e.g. an undeclared identifier: an objective WGSL
#                            spec violation, and the validator is the very
#                            front end that accepted the input). Counted in
#                            the denominator. This is the silent-wrong class.
#   CRASH                    zioshade died by signal/panic. Mandate violation.
#
# Corpus: tests/webgpu_cts (vendored; see its README.md). Regenerate with
# tools/webgpu_cts_fetch.sh. The sweep is corpus-agnostic: any dir with
# cases/*.wgsl + manifest.tsv (columns id, wgsl, entry, stage, spec, test,
# params) slots in via the dir argument.
#
# This is a CREDIBILITY REPORT, not a conformance claim and NOT a gate:
#   - It does NOT claim any WebGPU CTS pass. The CTS executes runtime
#     semantics on a real GPU; this harness measures INGESTION AND LOWERING
#     VALIDITY of a CTS-derived corpus through a SPIR-V round trip. The number
#     answers "how much CTS WGSL survives the round trip", nothing else.
#   - It is NON-GATING (report-only, like the breadth half of
#     tools/cts_ingestion_sweep.sh): invalid output is expected breadth on an
#     unfamiliar corpus. The one hard signal is a CRASH, printed LOUDLY here
#     and tracked against the baseline in tests/webgpu_cts/baseline.txt.
#
# FAILS CLOSED on harness breakage (the tools/metamorphic_check.sh discipline):
# a missing naga, an unbuilt CLI, an empty corpus, a manifest that disagrees
# with the case files, or a classifier that loses cases is a hard exit 2. A
# harness that measures nothing must never print a green zero.
#
# Usage: tools/webgpu_cts_sweep.sh [corpus-dir]        (default tests/webgpu_cts)
#   VERBOSE=1             print one verdict line per case
#   PER_CASE=<path>       also write the per-case verdict table there (this is
#                         how tests/webgpu_cts/per_case.tsv gets refreshed)
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
CORPUS=${1:-tests/webgpu_cts}
PER_CASE=${PER_CASE:-}

# ---- optional second upstream converter (tint) ----
# Explicit TINT that is not executable is a hard error (a configured-but-broken
# fallback must never silently degrade to naga-only numbers). Unset + not on
# PATH simply means naga-only, the original behavior.
TINT_BIN=${TINT:-}
if [ -z "$TINT_BIN" ] && command -v tint >/dev/null 2>&1; then
  TINT_BIN=$(command -v tint)
fi
if [ -n "${TINT:-}" ] && [ ! -x "$TINT_BIN" ]; then
  echo "error: TINT=$TINT is not executable"; exit 2
fi

# ---- fail-closed setup checks ----
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }
command -v naga >/dev/null || { echo "error: naga not on PATH (needed for BOTH the WGSL -> SPIR-V upstream leg and output validation)"; exit 2; }
[ -d "$CORPUS/cases" ] || { echo "error: corpus not found at $CORPUS/cases"; exit 2; }
[ -f "$CORPUS/manifest.tsv" ] || { echo "error: $CORPUS/manifest.tsv missing"; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VERDICTS="$TMP/per_case.tsv"
echo "id	verdict	spec	test" > "$VERDICTS"

# A zioshade invocation that died by signal / Zig panic rather than refusing
# loudly. A crash on valid input is a mandate violation (silent wrong).
is_crash() {
  local errfile=$1 rc=$2
  [ "$rc" -gt 128 ] && return 0
  grep -qiE 'thread .main. panicked|reached unreachable|abort trap|trace/breakpoint trap|segmentation fault|sigsegv|sigabrt' "$errfile" 2>/dev/null && return 0
  return 1
}

v_ok=0; v_upstream=0; v_refused=0; v_invalid=0; v_crash=0
crash_files=""
total=0

# manifest.tsv columns: id  wgsl  entry  stage  spec  test  params
while IFS=$'\t' read -r id wgsl entry stage spec test params; do
  case "$id" in id) continue;; esac   # header row
  total=$((total+1))
  src="$CORPUS/$wgsl"
  if [ ! -f "$src" ]; then
    echo "HARNESS BREAKAGE: manifest row $id -> missing file $src" >&2
    exit 2
  fi
  # ---- leg 1: CTS WGSL -> SPIR-V (naga, the upstream converter; tint second) ----
  if naga --input-kind wgsl "$src" "$TMP/case.spv" >"$TMP/e1" 2>&1; then
    :
  elif [ -n "$TINT_BIN" ] && "$TINT_BIN" --format spirv "$src" -o "$TMP/case.spv" >"$TMP/e1" 2>&1 && [ -s "$TMP/case.spv" ]; then
    # naga refused (e.g. subgroups-enabled WGSL) but tint converted: the case
    # still measures the SAME zioshade + naga-validate legs below.
    :
  else
    v_upstream=$((v_upstream+1))
    printf '%s\tupstream-convert-failed\t%s\t%s\n' "$id" "$spec" "$test" >> "$VERDICTS"
    [ -n "${VERBOSE:-}" ] && echo "$id: upstream-convert-failed ($(head -c 120 "$TMP/e1" | tr '\n' ' '))"
    continue
  fi
  # ---- leg 2: zioshade SPIR-V -> WGSL ----
  # Only pass --entry-point when the case's entry is not literally "main":
  # the CLI default already resolves a module's own entry. ep_args stays empty
  # otherwise (guarded expansion: macOS bash 3.2 + set -u).
  ep_args=()
  if [ "$entry" != "main" ]; then ep_args=(--entry-point "$entry"); fi
  if "$CLI" wgsl "$TMP/case.spv" ${ep_args[@]+"${ep_args[@]}"} -o "$TMP/out.wgsl" >"$TMP/e2" 2>&1; then
    # ---- leg 3: validate zioshade's WGSL (naga again) ----
    if naga "$TMP/out.wgsl" >/dev/null 2>&1; then
      v_ok=$((v_ok+1))
      printf '%s\troundtrip-valid\t%s\t%s\n' "$id" "$spec" "$test" >> "$VERDICTS"
      [ -n "${VERBOSE:-}" ] && echo "$id: roundtrip-valid"
    else
      v_invalid=$((v_invalid+1))
      printf '%s\tzioshade-invalid\t%s\t%s\n' "$id" "$spec" "$test" >> "$VERDICTS"
      [ -n "${VERBOSE:-}" ] && echo "$id: zioshade-invalid"
    fi
  else
    rc=$?
    if is_crash "$TMP/e2" "$rc"; then
      v_crash=$((v_crash+1)); crash_files="$crash_files $id"
      printf '%s\tCRASH\t%s\t%s\n' "$id" "$spec" "$test" >> "$VERDICTS"
      echo "CRASH: $id ($spec '$test', rc=$rc)"
    else
      v_refused=$((v_refused+1))
      printf '%s\tzioshade-refused\t%s\t%s\n' "$id" "$spec" "$test" >> "$VERDICTS"
      [ -n "${VERBOSE:-}" ] && echo "$id: zioshade-refused ($(head -c 120 "$TMP/e2" | tr '\n' ' '))"
    fi
  fi
done < "$CORPUS/manifest.tsv"

# ---- fail-closed result checks ----
[ "$total" -eq 0 ] && { echo "error: manifest enumerated zero cases"; exit 2; }
n_files=$(ls "$CORPUS"/cases/*.wgsl 2>/dev/null | wc -l | tr -d ' ')
if [ "$n_files" -ne "$total" ]; then
  echo "error: $n_files case files but $total manifest rows -- corpus and manifest disagree"; exit 2
fi
if [ $((v_ok + v_upstream + v_refused + v_invalid + v_crash)) -ne "$total" ]; then
  echo "error: verdict classes do not sum to the case count -- classifier lost cases"; exit 2
fi
# Zero valid AND not everything died upstream means the zioshade leg broke.
if [ "$v_ok" -eq 0 ] && [ "$v_upstream" -ne "$total" ]; then
  echo "error: zero roundtrip-valid cases without a full upstream failure -- zioshade leg is broken (fails closed)"; exit 2
fi

if [ -n "$PER_CASE" ]; then
  cp "$VERDICTS" "$PER_CASE" || echo "warning: could not write per-case table to $PER_CASE"
fi

echo
echo "WebGPU CTS (webgpu:shader) WGSL round-trip sweep: $total cases ($CORPUS)"
echo "  roundtrip-valid:          $v_ok"
echo "  upstream-convert-failed:  $v_upstream   (naga${TINT_BIN:+ AND tint} WGSL->SPIR-V refused; not zioshade's)"
echo "  zioshade-refused:         $v_refused   (honest error: nonzero exit + diagnostic)"
echo "  zioshade-invalid:         $v_invalid   (exit 0, naga rejects the output: silent-wrong class)"
echo "  CRASH:                    $v_crash   (mandate violation)"
[ -n "$crash_files" ] && echo "  crash cases:$crash_files"
echo "Report-only (non-gating). Compare against $CORPUS/baseline.txt."
exit 0
