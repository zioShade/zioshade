#!/usr/bin/env bash
# Two-oracle WGSL-LANGUAGE validity sweep (r2d.1, increment 1).
#
# Feeds every fixture through zioshade's WGSL backend and validates the emitted WGSL
# against BOTH naga (the Rust WGSL reference) AND tint (Chrome's WGSL compiler, a fully
# independent spec-reference oracle). Agreement between two independent oracles is much
# stronger evidence than either alone.
#
# SCOPE -- this sweep checks WGSL-LANGUAGE validity ONLY (parse + type-check + uniformity
# analysis + struct-indexability of the emitted text). It does NOT prove the shader will
# RUN in a real WebGPU consumer: pipeline/binding/layout validation needs execution against
# a concrete pipeline layout, which is a later increment. So a PASS here means "valid WGSL
# text", not "WebGPU-runnable".
#
# ORACLE PRIOR (how to read the buckets):
#   tint is the STRICTER / more spec-complete oracle -- it enforces rules naga
#   under-enforces (e.g. uniform control flow around texture/sample operations). Hence:
#     TINT-REJECT (tint rejects, naga accepts) = HIGH-CONFIDENCE bug lead -- tint caught a
#       spec violation naga let through.
#     NAGA-REJECT (naga rejects, tint accepts) = read with the prior "naga may be over-strict
#       here" -- could be a real zioshade bug OR a naga false-rejection; needs a human look.
#
# Buckets:
#   PASS              both naga + tint accept the zioshade WGSL
#   TINT-REJECT       tint rejects, naga accepts  -- high-confidence bug lead
#   NAGA-REJECT       naga rejects, tint accepts  -- bug lead (naga may be over-strict)
#   BOTH-REJECT       both reject                 -- honest-error / unsupported WGSL feature
#   SKIP-UNSUPPORTED  zioshade honest WGSL-feature refusal (Unsupported / no WGSL equivalent)
#   SKIP-NO-RUNNABLE  filtered out / compile-fail / otherwise not WGSL-runnable
#   SKIP-TINT-UNAVAIL zioshade emitted WGSL but the tint arm could not run
#                     (tint absent / wrong-arch / failed smoke test)
#   CRASH             zioshade crashed (signal/panic) -- mandate violation, surfaced loudly
#
# tint is auto-downloaded + cached under .zig-cache/tint on first use. The prebuilt is
# published for macos-aarch64 ONLY: on any other host (Linux/Windows/x86) the tint arm is
# skipped with a clear NOTE -- never silently false-reject. After download the binary is
# SMOKE-TESTED (a valid-WGSL round-trip) before being trusted: a wrong-arch binary passes
# the executable-bit check but fails to execute (ENOEXEC), which without the guard would
# turn every naga-PASS shader into a false TINT-REJECT. If offline, the tint arm is skipped
# with a clear message (run once online to populate the cache).
#
# IMPORTANT: the tint CLI's DEFAULT output format is SPIR-V, but the prebuilt build has
# the SPIR-V writer DISABLED, so a bare `tint file.wgsl` always errors with
# "SPIR-V writer not enabled in tint build". The correct validation invocation is an
# EXPLICIT WGSL round-trip: `tint --format wgsl <file>` (rc=0 = accept, rc=1 = reject with
# a stderr message). NOTE: tint has NO --version flag (it is "unknown flag", rc=1) -- the
# only clean liveness probe is the WGSL round-trip itself, which is what the smoke test
# uses. tint must fully parse + resolve (type/semantic-check) the input before it can emit,
# so the round-trip is a complete validity oracle. Confirmed empirically.
#
# Handles both .spv binary input (zioshade wgsl <spv>) and GLSL source (stage detected
# from the file extension, zioshade wgsl <src> --stage <st>). Report-only, NOT CI-gating
# (mirrors wgsl_naga_sweep, which is deliberately not in `ci`); non-zero exit only on a
# zioshade CRASH (mandate violation). A baseline/regression-gate mechanism is DEFERRED to
# when this sweep is promoted into CI -- not added here.
#
# Usage: tools/wgsl_tint_sweep.sh [corpus-dir ...]
#   default corpora: tests/cts/graphicsfuzz tests/integer_corpus
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
NAGA=${NAGA:-naga}
TINT_DIR=${TINT_DIR:-.zig-cache/tint}
TINT="$TINT_DIR/tint"
# Build id baked into the prebuilt URL; echoed in the report header so a future changed
# binary does not silently move the goalposts.
TINT_BUILD=7213
TINT_URL="https://github.com/eliemichel/dawn-prebuilt/releases/download/tint/${TINT_BUILD}/Tint-${TINT_BUILD}-macos-aarch64-Release.zip"

CORPORA=("$@")
[ ${#CORPORA[@]} -eq 0 ] && CORPORA=(tests/cts/graphicsfuzz tests/integer_corpus)

if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
  echo "error: zioshade CLI not found at $CLI -- run \`mise exec -- zig build\` first" >&2
  exit 2
fi

# Temp dir is created early so the tint smoke test can use it.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---- first oracle: naga (required) ----
HAVE_NAGA=0; command -v "$NAGA" >/dev/null 2>&1 && HAVE_NAGA=1
if [ "$HAVE_NAGA" = 0 ]; then
  echo "error: naga not on PATH (first oracle; install with \`cargo install naga-cli\`)" >&2
  exit 2
fi

# ---- second oracle: tint (auto-download + cache, platform-guarded + smoke-tested) ----
# tint_smoke: returns 0 iff $TINT actually executes AND validates WGSL. Guards against a
# wrong-arch binary (the executable-bit check passes but exec fails ENOEXEC, rc=126/127)
# AND a degenerate empty file (the shell runs it as a no-op script -> rc=0 with no output,
# hence the required '@vertex' marker in stdout). Confirmed empirically: a real tint
# round-trips the snippet with rc=0; a wrong-arch binary yields rc!=0 and empty stdout.
tint_smoke() {
  printf '@vertex\nfn v(@builtin(vertex_index) i:u32) -> @builtin(position) vec4<f32> {\n  return vec4<f32>();\n}\n' >"$TMP/smoke.wgsl"
  "$TINT" --format wgsl "$TMP/smoke.wgsl" >"$TMP/smoke.out" 2>/dev/null
  local rc=$?
  [ "$rc" -eq 0 ] && grep -q '@vertex' "$TMP/smoke.out" 2>/dev/null
}

HAVE_TINT=0
TINT_REASON="not attempted"
TINT_SHA=""
HOST_OS_ARCH="$(uname -sm 2>/dev/null)"   # e.g. "Darwin arm64"

# Platform guard: the prebuilt is macos-aarch64 ONLY. On any other host, skip the tint arm
# with a clear NOTE rather than downloading a wrong-arch binary that -x would trust.
if [ "$HOST_OS_ARCH" != "Darwin arm64" ]; then
  TINT_REASON="prebuilt unavailable for this host ($HOST_OS_ARCH; macos-aarch64 only)"
  echo "NOTE: tint $TINT_REASON -- skipping tint arm." >&2
else
  if [ -x "$TINT" ] && tint_smoke; then
    HAVE_TINT=1
  else
    if [ -x "$TINT" ]; then
      TINT_REASON="cached binary failed smoke test (corrupt/wrong-arch?)"
      echo "NOTE: $TINT_REASON -- re-downloading." >&2
    fi
    echo "tint not usable; downloading to $TINT_DIR ..." >&2
    if mkdir -p "$TINT_DIR" 2>/dev/null \
       && curl -sL --fail -o "$TINT_DIR/tint.zip" "$TINT_URL" 2>/dev/null; then
      ( cd "$TINT_DIR" \
        && unzip -o -q tint.zip \
        && d=$(ls -d Tint-*-macos-aarch64-Release 2>/dev/null | head -1) \
        && [ -n "$d" ] && mv "$d/tint" . && chmod +x tint && rm -rf "$d" tint.zip ) 2>/dev/null
      xattr -dr com.apple.quarantine "$TINT" 2>/dev/null || true
      if tint_smoke; then
        HAVE_TINT=1
      else
        TINT_REASON="downloaded binary failed smoke test (corrupt/wrong-arch?)"
        echo "NOTE: tint $TINT_REASON -- skipping tint arm." >&2
      fi
    else
      TINT_REASON="download failed (offline?)"
    fi
    if [ "$HAVE_TINT" = 0 ]; then
      echo "NOTE: tint $TINT_REASON -- tint arm will be skipped." >&2
      echo "      Run once online to populate $TINT, or place a tint binary there manually." >&2
    fi
  fi
  # sha256 for the report header (best-effort; non-fatal if shasum is unavailable).
  if [ "$HAVE_TINT" = 1 ] && command -v shasum >/dev/null 2>&1; then
    TINT_SHA="$(shasum -a 256 "$TINT" 2>/dev/null | awk '{print $1}')"
  fi
fi

# ---- report header (provenance + framing), printed first ----
echo "=== two-oracle WGSL-LANGUAGE validity sweep ==="
echo "host:             $HOST_OS_ARCH"
if [ "$HAVE_TINT" = 1 ]; then
  echo "tint:             $TINT (build $TINT_BUILD${TINT_SHA:+, sha256 $TINT_SHA})"
else
  echo "tint:             UNAVAILABLE -- $TINT_REASON"
fi
echo "scope:            WGSL-LANGUAGE validity (parse + type + uniformity); NOT WebGPU-consumer runnability"
echo "prior:            tint is the stricter oracle -> TINT-REJECT = high-confidence bug; NAGA-REJECT = naga may be over-strict"
echo ""

# A zioshade invocation that died by signal / Zig panic rather than refusing loudly. A
# crash on valid input is a mandate violation and must NOT be counted as honest-error.
is_crash() {
  local errfile=$1 rc=$2
  [ "$rc" -gt 128 ] && return 0
  grep -qiE 'thread .main. panicked|reached unreachable|abort trap|trace/breakpoint trap|segmentation fault|sigsegv|sigabrt' "$errfile" 2>/dev/null && return 0
  return 1
}

# GLSL-source -> zioshade --stage flag (WGSL only has vertex/fragment/compute; the other
# stages are passed through and zioshade honest-errors them, which the sweep counts SKIP).
stage_of() {
  case "$(basename "$1")" in
    *.vert|*.v.glsl) echo vertex;;
    *.comp|*.c.glsl) echo compute;;
    *.geom)          echo geometry;;
    *.tesc)          echo tessellation_control;;
    *.tese)          echo tessellation_evaluation;;
    *)               echo fragment;;
  esac
}

# naga validates a .wgsl file directly. Retry once to absorb transient spawn/file races
# (mirrors wgsl_naga_sweep's dependable-count logic); a real rejection is deterministic.
# Sets $NAGA_OK (1=accept, 0=reject) and writes the first error line to $NAGA_MSG.
NAGA_OK=0; NAGA_MSG=""
naga_validate() {
  local wgsl=$1 err="$TMP/naga.err"
  NAGA_OK=0; NAGA_MSG=""
  if "$NAGA" "$wgsl" >/dev/null 2>"$err" || "$NAGA" "$wgsl" >/dev/null 2>"$err"; then
    NAGA_OK=1
  else
    NAGA_MSG=$(head -1 "$err" 2>/dev/null | tr -d '\r')
  fi
}
# tint requires --format wgsl (its default SPIR-V output is disabled in this build -- see
# header). Retry once for the same race-absorption reason. Sets $TINT_OK + $TINT_MSG.
TINT_OK=0; TINT_MSG=""
tint_validate() {
  local wgsl=$1 err="$TMP/tint.err"
  TINT_OK=0; TINT_MSG=""
  if "$TINT" --format wgsl "$wgsl" >/dev/null 2>"$err" || "$TINT" --format wgsl "$wgsl" >/dev/null 2>"$err"; then
    TINT_OK=1
  else
    # strip the temp-dir prefix from tint's "<path>:<line>:<col> error: ..." for readability
    TINT_MSG=$(head -1 "$err" 2>/dev/null | tr -d '\r' | sed "s|^${TMP}/||")
  fi
}

# ---- aggregate (across all corpora) ----
A_PASS=0; A_TINT=0; A_NAGA=0; A_BOTH=0
A_SKIP_UNSUP=0; A_SKIP_NORUN=0; A_SKIP_TINT=0; A_CRASH=0
TINT_LEADS=""; NAGA_LEADS=""
SAMPLE_TINT_ERR=""

for dir in "${CORPORA[@]}"; do
  [ -d "$dir" ] || { echo "(skip: corpus not found at $dir)"; continue; }
  pass=0; trej=0; nrej=0; both=0; crash=0
  skip_unsup=0; skip_norun=0; skip_tint=0
  while IFS= read -r f; do
    base=$(basename "$f")
    case "$base" in *.asm.*|*.error.*|link.*|*.nocompat.*) continue;; esac
    is_spv=0
    case "$base" in *.spv) is_spv=1;; esac
    # GLSL-source filters (meaningless on a binary .spv): need an entry point, skip ERRORs.
    if [ "$is_spv" = 0 ]; then
      grep -q "void main\|void mainImage" "$f" 2>/dev/null || { skip_norun=$((skip_norun+1)); continue; }
      grep -q "// ERROR" "$f" 2>/dev/null && { skip_norun=$((skip_norun+1)); continue; }
    fi

    # ---- zioshade -> WGSL ----
    if [ "$is_spv" = 1 ]; then
      "$CLI" wgsl "$f" >"$TMP/o.wgsl" 2>"$TMP/zs.err"
    else
      "$CLI" wgsl "$f" --stage "$(stage_of "$f")" >"$TMP/o.wgsl" 2>"$TMP/zs.err"
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if is_crash "$TMP/zs.err" "$rc"; then
        crash=$((crash+1)); echo "CRASH $base (rc=$rc)"
      elif grep -qiE 'Unsupported|no WGSL equivalent' "$TMP/zs.err" 2>/dev/null; then
        skip_unsup=$((skip_unsup+1))   # honest WGSL-feature refusal (mirrors wgsl_naga_sweep)
      else
        skip_norun=$((skip_norun+1))   # compile-fail / frontend rejection / otherwise not runnable
      fi
      continue
    fi

    # ---- oracle verdicts ----
    naga_validate "$TMP/o.wgsl"
    if [ "$HAVE_TINT" = 1 ]; then
      tint_validate "$TMP/o.wgsl"
    else
      TINT_OK=-1   # tint unavailable -> cannot classify; counted SKIP-TINT-UNAVAILABLE below
    fi
    if [ "$TINT_OK" = -1 ]; then
      skip_tint=$((skip_tint+1)); continue
    fi

    if [ "$NAGA_OK" = 1 ] && [ "$TINT_OK" = 1 ]; then
      pass=$((pass+1))
    elif [ "$NAGA_OK" = 0 ] && [ "$TINT_OK" = 0 ]; then
      both=$((both+1))
    elif [ "$TINT_OK" = 0 ]; then
      # naga accepts, tint rejects -- TINT-REJECT bug lead (tint is stricter -> high-confidence)
      trej=$((trej+1)); TINT_LEADS="${TINT_LEADS}${base}"$'\n'
      [ -z "$SAMPLE_TINT_ERR" ] && SAMPLE_TINT_ERR="$TINT_MSG"
      echo "TINT-REJECT $base  -- $TINT_MSG"
    else
      # naga rejects, tint accepts -- NAGA-REJECT bug lead (naga may be over-strict)
      nrej=$((nrej+1)); NAGA_LEADS="${NAGA_LEADS}${base}"$'\n'
      echo "NAGA-REJECT $base  -- $NAGA_MSG"
    fi
  done < <(find "$dir" -type f \( -name '*.spv' -o -name '*.frag' -o -name '*.vert' -o -name '*.comp' -o -name '*.glsl' \))

  A_PASS=$((A_PASS+pass)); A_TINT=$((A_TINT+trej)); A_NAGA=$((A_NAGA+nrej))
  A_BOTH=$((A_BOTH+both))
  A_SKIP_UNSUP=$((A_SKIP_UNSUP+skip_unsup)); A_SKIP_NORUN=$((A_SKIP_NORUN+skip_norun))
  A_SKIP_TINT=$((A_SKIP_TINT+skip_tint)); A_CRASH=$((A_CRASH+crash))
  skip_total=$((skip_unsup + skip_norun + skip_tint))

  echo ""
  echo "=== $dir ==="
  echo "  PASS (both):       $pass"
  echo "  TINT-REJECT:       $trej   (tint rejects, naga accepts -- high-confidence bug leads)"
  echo "  NAGA-REJECT:       $nrej   (naga rejects, tint accepts -- naga may be over-strict)"
  echo "  BOTH-REJECT:       $both   (honest-error / unsupported)"
  echo "  SKIP-UNSUPPORTED:  $skip_unsup   (zioshade honest WGSL-feature refusal)"
  echo "  SKIP-NO-RUNNABLE:  $skip_norun   (filtered / compile-fail / not WGSL-runnable)"
  echo "  SKIP-TINT-UNAVAIL: $skip_tint   (tint arm absent / wrong-arch / failed smoke)"
  echo "  SKIP (total):      $skip_total"
  [ "$crash" -gt 0 ] && echo "  CRASH:             $crash  (mandate violation)"
done

A_SKIP_TOTAL=$((A_SKIP_UNSUP + A_SKIP_NORUN + A_SKIP_TINT))

echo ""
echo "=== two-oracle WGSL-LANGUAGE validity sweep -- AGGREGATE ==="
echo "PASS (both naga+tint accept): $A_PASS"
echo "TINT-REJECT (high-conf bug):  $A_TINT"
echo "NAGA-REJECT (naga over-strict?): $A_NAGA"
echo "BOTH-REJECT (unsupported):    $A_BOTH"
echo "SKIP-UNSUPPORTED:             $A_SKIP_UNSUP"
echo "SKIP-NO-RUNNABLE:             $A_SKIP_NORUN"
echo "SKIP-TINT-UNAVAILABLE:        $A_SKIP_TINT"
echo "SKIP (total):                 $A_SKIP_TOTAL"
[ "$A_CRASH" -gt 0 ] && echo "CRASH (mandate violation):    $A_CRASH"
if [ "$HAVE_TINT" = 0 ]; then
  echo "NOTE: tint was unavailable ($TINT_REASON); with no tint arm every emitted WGSL falls"
  echo "      into SKIP-TINT-UNAVAILABLE and TINT-REJECT/NAGA-REJECT stay empty by definition."
fi
if [ -n "$TINT_LEADS" ]; then
  echo ""
  echo "--- TINT-REJECT shaders (tint rejects, naga accepts) ---"
  printf "%s" "$TINT_LEADS"
fi
if [ -n "$NAGA_LEADS" ]; then
  echo ""
  echo "--- NAGA-REJECT shaders (naga rejects, tint accepts) ---"
  printf "%s" "$NAGA_LEADS"
fi
if [ -n "$SAMPLE_TINT_ERR" ]; then
  echo ""
  echo "sample tint error: $SAMPLE_TINT_ERR"
fi

# Non-zero exit ONLY on a zioshade CRASH (mandate violation). TINT/NAGA-REJECT are bug
# leads to investigate, not gate failures -- this sweep is report-only (mirrors
# wgsl_naga_sweep, which is deliberately not in `ci`).
[ "$A_CRASH" -gt 0 ] && exit 1
exit 0
