#!/usr/bin/env bash
# Two-oracle WGSL compile-validity sweep (r2d.1, increment 1).
#
# Feeds every fixture through zioshade's WGSL backend and validates the emitted WGSL
# against BOTH naga (the Rust WGSL reference) AND tint (Chrome's WGSL compiler, a fully
# independent spec-reference oracle). Agreement between two independent oracles is much
# stronger evidence than either alone: a tint-REJECT that naga accepts (or vice versa) is
# a real WGSL emission bug lead to investigate -- never plausible-but-wrong.
#
# Buckets:
#   PASS         both naga + tint accept the zioshade WGSL
#   TINT-REJECT  tint rejects, naga accepts  -- bug lead (tint-only rejection)
#   NAGA-REJECT  naga rejects, tint accepts  -- bug lead (naga-only rejection)
#   BOTH-REJECT  both reject                 -- honest-error / unsupported WGSL feature
#   SKIP         zioshade refused (honest-error) or input not WGSL-runnable
#   CRASH        zioshade crashed (signal/panic) -- mandate violation, surfaced loudly
#
# tint is auto-downloaded + cached under .zig-cache/tint on first use. If offline, the
# tint arm is skipped with a clear message (run once online to populate the cache).
#
# IMPORTANT: the tint CLI's DEFAULT output format is SPIR-V, but the prebuilt build has
# the SPIR-V writer DISABLED, so a bare `tint file.wgsl` always errors with
# "SPIR-V writer not enabled in tint build". The correct validation invocation is an
# EXPLICIT WGSL round-trip: `tint --format wgsl <file>` (rc=0 = accept, rc=1 = reject with
# a stderr message). tint must fully parse + resolve (type/semantic-check) the input
# before it can emit, so the round-trip is a complete validity oracle. Confirmed
# empirically before this sweep was written.
#
# Handles both .spv binary input (zioshade wgsl <spv>) and GLSL source (stage detected
# from the file extension, zioshade wgsl <src> --stage <st>). Report-only, NOT CI-gating
# (mirrors wgsl_naga_sweep); non-zero exit only on a zioshade CRASH (mandate violation).
#
# Usage: tools/wgsl_tint_sweep.sh [corpus-dir ...]
#   default corpora: tests/cts/graphicsfuzz tests/integer_corpus
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
NAGA=${NAGA:-naga}
TINT_DIR=${TINT_DIR:-.zig-cache/tint}
TINT="$TINT_DIR/tint"
TINT_URL="https://github.com/eliemichel/dawn-prebuilt/releases/download/tint/7213/Tint-7213-macos-aarch64-Release.zip"

CORPORA=("$@")
[ ${#CORPORA[@]} -eq 0 ] && CORPORA=(tests/cts/graphicsfuzz tests/integer_corpus)

if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
  echo "error: zioshade CLI not found at $CLI -- run \`mise exec -- zig build\` first" >&2
  exit 2
fi

# ---- first oracle: naga (required) ----
HAVE_NAGA=0; command -v "$NAGA" >/dev/null 2>&1 && HAVE_NAGA=1
if [ "$HAVE_NAGA" = 0 ]; then
  echo "error: naga not on PATH (first oracle; install with \`cargo install naga-cli\`)" >&2
  exit 2
fi

# ---- second oracle: tint (auto-download + cache) ----
# The prebuilt tint is a single macOS-arm64 binary; cache it under .zig-cache/tint (same
# place the repo caches MslCompileCheck at .zig-cache/mslcheck). On first use, download +
# unzip + chmod + clear the macOS quarantine attribute. Offline -> skip the tint arm.
HAVE_TINT=0
if [ -x "$TINT" ]; then
  HAVE_TINT=1
else
  echo "tint not cached; downloading to $TINT_DIR ..." >&2
  if mkdir -p "$TINT_DIR" 2>/dev/null \
     && curl -sL --fail -o "$TINT_DIR/tint.zip" "$TINT_URL" 2>/dev/null; then
    ( cd "$TINT_DIR" \
      && unzip -o -q tint.zip \
      && d=$(ls -d Tint-*-macos-aarch64-Release 2>/dev/null | head -1) \
      && [ -n "$d" ] && mv "$d/tint" . && chmod +x tint && rm -rf "$d" tint.zip ) 2>/dev/null
    xattr -dr com.apple.quarantine "$TINT" 2>/dev/null || true
    [ -x "$TINT" ] && HAVE_TINT=1
  fi
  if [ "$HAVE_TINT" = 0 ]; then
    echo "NOTE: tint download failed (offline?) -- tint arm will be skipped." >&2
    echo "      Run once online to populate $TINT, or place a tint binary there manually." >&2
  fi
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

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
A_PASS=0; A_TINT=0; A_NAGA=0; A_BOTH=0; A_SKIP=0; A_CRASH=0
TINT_LEADS=""; NAGA_LEADS=""
SAMPLE_TINT_ERR=""

for dir in "${CORPORA[@]}"; do
  [ -d "$dir" ] || { echo "(skip: corpus not found at $dir)"; continue; }
  pass=0; trej=0; nrej=0; both=0; skip=0; crash=0
  while IFS= read -r f; do
    base=$(basename "$f")
    case "$base" in *.asm.*|*.error.*|link.*|*.nocompat.*) continue;; esac
    is_spv=0
    case "$base" in *.spv) is_spv=1;; esac
    # GLSL-source filters (meaningless on a binary .spv): need an entry point, skip ERRORs.
    if [ "$is_spv" = 0 ]; then
      grep -q "void main\|void mainImage" "$f" 2>/dev/null || { skip=$((skip+1)); continue; }
      grep -q "// ERROR" "$f" 2>/dev/null && { skip=$((skip+1)); continue; }
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
      else
        skip=$((skip+1))   # honest refusal (Unsupported / no WGSL equivalent / compile-fail)
      fi
      continue
    fi

    # ---- oracle verdicts ----
    naga_validate "$TMP/o.wgsl"
    if [ "$HAVE_TINT" = 1 ]; then
      tint_validate "$TMP/o.wgsl"
    else
      TINT_OK=-1   # tint unavailable -> cannot classify; counted SKIP below
    fi
    if [ "$TINT_OK" = -1 ]; then
      skip=$((skip+1)); continue
    fi

    if [ "$NAGA_OK" = 1 ] && [ "$TINT_OK" = 1 ]; then
      pass=$((pass+1))
    elif [ "$NAGA_OK" = 0 ] && [ "$TINT_OK" = 0 ]; then
      both=$((both+1))
    elif [ "$TINT_OK" = 0 ]; then
      # naga accepts, tint rejects -- TINT-REJECT bug lead
      trej=$((trej+1)); TINT_LEADS="${TINT_LEADS}${base}"$'\n'
      [ -z "$SAMPLE_TINT_ERR" ] && SAMPLE_TINT_ERR="$TINT_MSG"
      echo "TINT-REJECT $base  -- $TINT_MSG"
    else
      # naga rejects, tint accepts -- NAGA-REJECT bug lead
      nrej=$((nrej+1)); NAGA_LEADS="${NAGA_LEADS}${base}"$'\n'
      echo "NAGA-REJECT $base  -- $NAGA_MSG"
    fi
  done < <(find "$dir" -type f \( -name '*.spv' -o -name '*.frag' -o -name '*.vert' -o -name '*.comp' -o -name '*.glsl' \))

  A_PASS=$((A_PASS+pass)); A_TINT=$((A_TINT+trej)); A_NAGA=$((A_NAGA+nrej))
  A_BOTH=$((A_BOTH+both)); A_SKIP=$((A_SKIP+skip)); A_CRASH=$((A_CRASH+crash))

  echo ""
  echo "=== $dir ==="
  echo "  PASS (both):       $pass"
  echo "  TINT-REJECT:       $trej   (tint rejects, naga accepts -- bug leads)"
  echo "  NAGA-REJECT:       $nrej   (naga rejects, tint accepts -- bug leads)"
  echo "  BOTH-REJECT:       $both   (honest-error / unsupported)"
  echo "  SKIP:              $skip   (zioshade refused / not runnable)"
  [ "$crash" -gt 0 ] && echo "  CRASH:             $crash  (mandate violation)"
done

echo ""
echo "=== two-oracle WGSL validity sweep -- AGGREGATE ==="
echo "PASS (both naga+tint accept): $A_PASS"
echo "TINT-REJECT (bug leads):      $A_TINT"
echo "NAGA-REJECT (bug leads):      $A_NAGA"
echo "BOTH-REJECT (unsupported):    $A_BOTH"
echo "SKIP:                         $A_SKIP"
[ "$A_CRASH" -gt 0 ] && echo "CRASH (mandate violation):    $A_CRASH"
if [ "$HAVE_TINT" = 0 ]; then
  echo "NOTE: tint was unavailable; TINT-REJECT/NAGA-REJECT/PASS buckets are empty by definition."
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
