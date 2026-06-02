#!/usr/bin/env bash
# Large-corpus WGSL <-> naga differential.
#
# Compiles every conformance GLSL fixture to WGSL via glslpp and validates the
# result with naga (the WGSL reference). Reports:
#   naga PASS            glslpp WGSL accepted by naga
#   naga REJECT          glslpp emitted WGSL that naga rejects  <-- a divergence
#                        (silent-wrong) to fix; the goal is ZERO of these.
#   honest-unsupported   glslpp returned a named error.Unsupported* (acceptable —
#                        an honest refusal, not silent-wrong)
#   GLSL compile-fail    GLSL->SPIR-V failed before WGSL (pre-existing / unrelated)
#
# This is backlog item #2's "WGSL vs naga (large corpus)" differential and the
# measurable target for #3's WGSL deepening. Run: `just wgsl-naga`.
#
# Filters the same non-compilable fixtures the spirv-val conformance runner skips
# (.asm SPIR-V-assembly, .error validation tests, link.* multi-file, .nocompat).
set -uo pipefail

CLI="${CLI:-zig-out/bin/glslpp.exe}"
NAGA="${NAGA:-naga}"
TMP=".zig-cache/wgsl-naga-sweep.wgsl"
# WGSL only has vertex/fragment/compute entry points (no geometry/tessellation/
# mesh/ray), so the sweep covers only those stages — counting WGSL-impossible
# stages as "REJECT" would be meaningless noise. (glslpp emitting WGSL for an
# unsupported stage instead of honest-erroring is a separate issue, tracked.)
SUITES="${SUITES:-tests/spirv-cross tests/glslang-430 tests/ghostty tests/compute tests/conformance/stress tests/external}"

if [ ! -x "$CLI" ] && [ ! -f "$CLI" ]; then
  echo "error: glslpp CLI not found at $CLI — run \`mise exec -- zig build\` first" >&2
  exit 2
fi

pass=0; nfail=0; unsup=0; cfail=0; skip=0
fails=""

for dir in $SUITES; do
  [ -d "$dir" ] || continue
  while IFS= read -r f; do
    base=$(basename "$f")
    case "$base" in *.asm.*|*.error.*|link.*|*.nocompat.*) continue;; esac
    grep -q "void main\|void mainImage" "$f" 2>/dev/null || { skip=$((skip+1)); continue; }
    if grep -q "// ERROR" "$f" 2>/dev/null; then skip=$((skip+1)); continue; fi
    case "$base" in
      *.vert|*.v.glsl) st=vertex;;
      *.comp|*.c.glsl) st=compute;;
      *.geom) st=geometry;;
      *.tesc) st=tessellation_control;;
      *.tese) st=tessellation_evaluation;;
      *) st=fragment;;
    esac
    out=$("$CLI" wgsl "$f" --stage "$st" -o "$TMP" 2>&1)
    if [ $? -ne 0 ]; then
      if echo "$out" | grep -qiE "Unsupported|no WGSL equivalent"; then
        unsup=$((unsup+1))
      else
        cfail=$((cfail+1))
      fi
      continue
    fi
    # Retry once on failure: a REAL naga rejection is deterministic and fails
    # both times, but a transient Windows file/AV/spawn race (which jittered the
    # raw count run-to-run) typically succeeds on the retry. This keeps the count
    # dependable without ever masking a genuine divergence.
    if "$NAGA" "$TMP" >/dev/null 2>&1 || "$NAGA" "$TMP" >/dev/null 2>&1; then
      pass=$((pass+1))
    else
      nfail=$((nfail+1))
      fails="${fails}${f}"$'\n'
    fi
  done < <(find "$dir" -type f \( -name '*.frag' -o -name '*.vert' -o -name '*.comp' -o -name '*.glsl' \))
done

echo "=== WGSL <-> naga large-corpus differential ==="
echo "naga PASS:           $pass"
echo "naga REJECT (fix):   $nfail"
echo "honest-unsupported:  $unsup"
echo "GLSL compile-fail:   $cfail"
echo "skipped:             $skip"
if [ -n "$fails" ]; then
  echo ""
  echo "--- naga rejections (glslpp WGSL that naga rejects — divergences to fix) ---"
  printf "%s" "$fails"
fi
rm -f "$TMP" 2>/dev/null || true
