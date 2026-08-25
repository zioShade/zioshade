#!/usr/bin/env bash
# WGSL render proxy - render-verify zioshade's WGSL output on Metal (no wgpu needed).
#
# zioshade's WGSL output is round-tripped: zioshade WGSL ->(naga --input-kind wgsl)->
# SPIR-V ->(spirv-cross --msl)-> MSL, then render-diffed on Metal vs MSL_ref
# (spirv-cross --msl of the SOURCE SPIR-V). MATCH = zioshade's WGSL output renders
# identically to the reference = WGSL render-correct (as naga parses it). Catches WGSL
# emission bugs that the compile-only naga gate (wgsl_naga_sweep) misses.
#
# Same caveat as the GLSL/HLSL render proxies: a DIFFER on a chaotic shader is benign FP
# ordering divergence (no ground truth) - flagged, never auto-fixed.
#
# ── Corpora ──────────────────────────────────────────────────────────────────
# Default sweep: tests/spirv-cross AND tests/wintty_gallery (the wintty shader
# gallery, vendored verbatim; the shapes a shipping consumer compiles - the
# corpus that exposed the three silent-wrong bug classes no other gate saw).
# Pass explicit dirs to scope it: tools/wgsl_render_check.sh tests/integer_corpus
#
# ── Source leg (glslang) ─────────────────────────────────────────────────────
# The source SPIR-V is built by glslang, an oracle independent of zioshade's
# frontend, for every corpus including the gallery. Gallery sources must
# compile under glslang verbatim (the corpus README invariant): a refusal
# there is a broken gallery entry and FAILS the gate, never a reason to stage
# the source through zioshade's own frontend (that lower-rigor leg would
# silently absorb the next real refusal into a frontend-correlated
# comparison). In every other corpus a glslang refusal stays a plain
# skip-glslang (the historical behavior).
#
# ── Undefined-read sources (skip-undef-read) ────────────────────────────────
# A source that reads undefined Function memory (loop-dominator-and-switch-
# default reads `vec4 f4;` before any store) has NO deterministic reference:
# the spirv-cross leg keeps the variable uninitialized and renders whatever
# the GPU thread memory held (rendering that reference against itself differs
# on half the frame), while the WGSL leg must zero-initialize -- WGSL has no
# uninitialized var. No compiler output can reconcile the two, so such
# sources are skipped as a CLASS by tools/spv_undef_read.py (never by name;
# a miss stays a loud DIFFER). This is an oracle-validity limit, not a
# compiler pass/fail: the silent-wrong lowering bugs such shaders can still
# carry are gated by the minimized UB-free shapes in tests/wgsl_tests.zig
# and by every defined-memory shader in this sweep.
#
# ── Baseline / GATE semantics ────────────────────────────────────────────────
# This check is wired into `just ci-full`. It exits NONZERO on any NEW DIFFER
# and passes on known ones, so the standing (triaged) DIFFERs and the open WGSL
# bugs below cannot block CI while a fresh divergence still fails the gate.
# Expected DIFFERs are pinned in tools/wgsl_render_baseline.txt, one entry per
# line, format:
#     <corpus-dir>/<name>.frag: <reason>
# Every entry MUST cite a reason - a bug id, or triaged-and-accepted with one
# line of why. Regenerate with:
#     tools/wgsl_render_check.sh --update-baseline
# Existing reasons are preserved; new DIFFERs are added with a REQUIRED marker
# that must be replaced by a real reason before committing. Only the corpora
# swept in that invocation are rewritten (entries for other corpora pass
# through untouched). A baseline entry that no longer DIFFERs is reported
# STALE - remove it - but does not fail the gate, because fast-math EDGE
# reclassification can legitimately flap between machines.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI=${CLI:-zig-out/bin/zioshade}
SHARE=${SHARE:-/tmp/zioshade_wgsl_render}
BASELINE=${BASELINE:-tools/wgsl_render_baseline.txt}
mkdir -p "$SHARE"
SC=$SHARE/ShaderCompare
# Rebuild when the swift source is newer than the cached binary (a stale cache
# would silently keep testing the previous harness).
if [ ! -x "$SC" ] || [ tools/ShaderCompare.swift -nt "$SC" ]; then
  swiftc -O tools/ShaderCompare.swift -o "$SC" 2>/dev/null || { echo "error: swiftc failed"; exit 2; }
fi
command -v naga >/dev/null || { echo "error: naga not on PATH"; exit 2; }
command -v spirv-cross >/dev/null || { echo "error: spirv-cross not on PATH"; exit 2; }
command -v glslangValidator >/dev/null || { echo "error: glslangValidator not on PATH"; exit 2; }
[ -x "$CLI" ] || { echo "error: build the CLI first (zig build cli)"; exit 2; }

UPDATE_BASELINE=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--update-baseline" ]; then UPDATE_BASELINE=1; else ARGS+=("$a"); fi
done
DIRS=("${ARGS[@]}")
[ ${#DIRS[@]} -eq 0 ] && DIRS=(tests/spirv-cross tests/wintty_gallery)

# check_one runs AFTER "$d.src.spv" exists (the parent builds it so the
# counter bumps survive the command substitution subshell).
check_one() {
  local d="$1"
  spirv-cross --msl "$d.src.spv" > "$d.ref.msl" 2>/dev/null || { echo "skip-crossmsl"; return; }
  "$CLI" wgsl "$d.src.spv" --stage fragment > "$d.z.wgsl" 2>/dev/null || { echo "skip-zwgsl"; return; }
  naga --input-kind wgsl "$d.z.wgsl" "$d.z.spv" >/dev/null 2>&1 || { echo "skip-naga"; return; }
  spirv-cross --msl "$d.z.spv" > "$d.z.msl" 2>/dev/null || { echo "skip-zcrossmsl"; return; }
  local o; o=$("$SC" "$d.z.msl" "$d.ref.msl" "${d}_r" 2>&1)
  printf '%s' "$o" | grep -q '^MATCH' && { echo "MATCH"; return; }
  printf '%s' "$o" | grep -q 'SKIP(harness-binding)' && { echo "skip-binding"; return; }
  printf '%s' "$o" | grep -qE '^DIFFER' || { echo "skip-render"; return; }
  local md; md=$(printf '%s' "$o" | grep -oE 'Max channel diff: [0-9]+' | grep -oE '[0-9]+$')
  # #52 (Risk C): adjudicate benign fast-math FP - re-render precise (mathMode=.safe).
  local os; os=$(SHADERCOMPARE_SAFE_MATH=1 "$SC" "$d.z.msl" "$d.ref.msl" "${d}_rp" 2>&1)
  if printf '%s' "$os" | grep -q '^MATCH'; then echo "EDGE(fast-math-fp)"; else echo "DIFFER maxdiff=${md:-?}"; fi
}

declare -A C
REFUSED=()      # gallery sources glslang refused (broken gallery entries)
DIFFERS=()      # "key<TAB>verdict" for every DIFFER
bump() { C[$1]=$((${C[$1]:-0}+1)); }
for DIR in "${DIRS[@]}"; do
  alias_=$(basename "$DIR")
  # The gallery corpus needs the mid-animation cursor uniforms (ShaderCompare
  # env knob) or the mode-change shaders short-circuit to their static path
  # and their bug shapes never execute. Other corpora keep the historical set.
  # The same corpus also requires glslang to accept every source verbatim:
  # a refusal is a broken gallery entry and fails the gate (other corpora
  # keep the historical skip-glslang).
  REQUIRE_GLSLANG=0
  case "$DIR" in
    *wintty_gallery*)
      export SHADERCOMPARE_GALLERY_UNIFORMS=1
      REQUIRE_GLSLANG=1
      ;;
    *) unset SHADERCOMPARE_GALLERY_UNIFORMS || true;;
  esac
  for f in "$DIR"/*.frag; do
    case "$f" in *.asm.*) continue;; esac
    [ -e "$f" ] || continue
    name=$(basename "$f" .frag)
    key="$DIR/$name.frag"
    d="$SHARE/$alias_.$name"
    sed 's/^\(out [a-z0-9]*vec4 [A-Za-z_][A-Za-z0-9_]*;\)/layout(location=0) \1/' "$f" > "$d.g.frag"
    if ! glslangValidator -V -S frag "$d.g.frag" -o "$d.src.spv" >/dev/null 2>&1; then
      # glslang refuses the SOURCE. Gallery only (see header): a broken
      # gallery entry fails the gate; elsewhere keep the historical skip.
      if [ "$REQUIRE_GLSLANG" = 1 ]; then
        REFUSED+=("$key")
        continue
      fi
      bump skip-glslang; continue
    fi
    # #undef-read-oracle: a source that READS undefined Function memory (no
    # initializer, first read before any store, on the unconditional prefix;
    # tools/spv_undef_read.py documents the two conservative exclusions) has
    # no deterministic reference leg: spirv-cross keeps the variable
    # uninitialized, so the reference renders whatever the GPU thread memory
    # held (rendering the reference MSL against itself differs on half the
    # frame), while the WGSL leg must zero-initialize -- WGSL has no
    # uninitialized var, so no zioshade output can ever match. The comparison
    # is not an oracle for such a source; skip it as a CLASS (like
    # skip-binding: a harness limit, never a gate pass/fail), not per name.
    # A missing python3/spirv-dis degrades to compare-as-before.
    if python3 tools/spv_undef_read.py "$d.src.spv" >/dev/null 2>&1; then
      bump skip-undef-read; continue
    fi
    v=$(check_one "$d"); keyv=${v%% *}; bump "$keyv"
    case "$v" in DIFFER*) DIFFERS+=("$key"$'\t'"$v");; esac
  done
done

# ---- baseline compare: NEW DIFFERs fail, known ones pass with their reason ----
declare -A BASE
declare -A BASE_ORDER
if [ -f "$BASELINE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    p=${line%%:*}
    r=${line#*:}
    BASE[$p]="$r"
    BASE_ORDER[$p]=1
    case "$r" in ''|*'REQUIRED'*)
      echo "WARNING: baseline entry '$p' has no triaged reason (${r:-empty}) - every entry must cite a bug id or an accepted-why" >&2
      ;;
    esac
  done < "$BASELINE"
fi

NEW=0; KNOWN=0; STALE=0
declare -A SAW_DIFFER
echo ""
for e in "${DIFFERS[@]:-}"; do
  [ -z "$e" ] && continue
  k=${e%%$'\t'*}; v=${e#*$'\t'}
  SAW_DIFFER[$k]=1
  if [ -n "${BASE[$k]:-}" ]; then
    KNOWN=$((KNOWN+1))
    echo "KNOWN-DIFFER $k ($v) - accepted: ${BASE[$k]}"
  else
    NEW=$((NEW+1))
    echo "NEW-DIFFER   $k ($v)"
  fi
done

# STALE = baseline entries for a corpus swept this run that no longer DIFFER.
for p in "${!BASE_ORDER[@]}"; do
  swept=0
  for DIR in "${DIRS[@]}"; do
    case "$p" in "$DIR"/*) swept=1;; esac
  done
  if [ "$swept" = 1 ] && [ -z "${SAW_DIFFER[$p]:-}" ]; then
    STALE=$((STALE+1))
    echo "STALE       $p - no longer differs; remove the entry from $BASELINE"
  fi
done

if [ "$UPDATE_BASELINE" = 1 ]; then
  # Rewrite ONLY the swept corpora's entries; everything else passes through.
  tmp="$BASELINE.new"
  {
    echo "# Expected DIFFERs for tools/wgsl_render_check.sh (the WGSL render proxy)."
    echo "# Format: <corpus-dir>/<name>.frag: <reason>"
    echo "# Every entry MUST cite a reason: a bug id, or triaged-and-accepted + why."
    echo "# Regenerate: tools/wgsl_render_check.sh --update-baseline   (see tool header.)"
    echo ""
    for p in $(printf '%s\n' "${!BASE_ORDER[@]}" | sort); do
      swept=0
      for DIR in "${DIRS[@]}"; do
        case "$p" in "$DIR"/*) swept=1;; esac
      done
      [ "$swept" = 0 ] && { echo "$p: ${BASE[$p]}"; continue; }
      if [ -n "${SAW_DIFFER[$p]:-}" ]; then
        r=${BASE[$p]:-}
        case "$r" in ''|*'REQUIRED'*) r="REQUIRED: triage this DIFFER and cite a bug id or an accepted-why before committing";; esac
        echo "$p: $r"
      fi
    done
    for e in "${DIFFERS[@]:-}"; do
      [ -z "$e" ] && continue
      k=${e%%$'\t'*}
      [ -n "${BASE[$k]:-}" ] && continue
      echo "$k: REQUIRED: triage this DIFFER and cite a bug id or an accepted-why before committing"
    done
  } > "$tmp"
  # de-dup data lines for keys already rewritten above (comments/blank pass through)
  awk '/^#/ || NF == 0 { print; next } !seen[$1]++' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
  mv "$tmp" "$BASELINE"
  echo "baseline rewritten: $BASELINE (entries for swept corpora only; fill every REQUIRED before committing)"
fi

echo ""
echo "=== WGSL render proxy coverage ==="
for k in MATCH "EDGE(fast-math-fp)" DIFFER skip-binding skip-glslang skip-crossmsl skip-zwgsl skip-naga skip-zcrossmsl skip-render skip-undef-read; do
  echo "  $k: ${C[$k]:-0}"
done
NREF=${#REFUSED[@]}
echo "  glslang-refused (gate fail, gallery corpus): $NREF"
for r in "${REFUSED[@]:-}"; do
  [ -z "$r" ] && continue
  echo "    $r - gallery sources must compile under glslang verbatim (broken gallery entry)"
done
echo "  DIFFER known (baseline): $KNOWN"
echo "  DIFFER NEW (gate fail):  $NEW"
[ "$STALE" -gt 0 ] && echo "  baseline STALE entries:  $STALE (cleanup suggested)"

if [ "$NEW" -gt 0 ] || [ "$NREF" -gt 0 ]; then
  echo ""
  echo "WGSL RENDER GATE: FAIL ($NEW new divergence(s), $NREF glslang-refused source(s))"
  exit 1
fi
echo "WGSL RENDER GATE: PASS (no new divergences; $KNOWN known)"
exit 0
