#!/usr/bin/env bash
# Large-corpus MSL silent-wrong invariant sweep — the MSL analog of
# tools/wgsl_naga_sweep.sh. There is no Metal compiler on Windows, so we cannot
# validate MSL the way naga validates WGSL. Instead we emit MSL for every
# conformance fixture and assert a set of *invariants* that any valid MSL must
# satisfy. Each invariant is chosen to be ZERO-false-positive: a violation is
# unconditionally invalid MSL, never a mere stylistic difference from spirv-cross.
#
# Invariants:
#   INV1 (pointer-dot): a parameter declared `device/constant/threadgroup T* name`
#     accessed directly as `name.` (dot) is invalid — a pointer needs `->` or
#     `(*name).` or `name[i].`. (`name[i].m` and `(*name).m` do NOT match `\bname\.`.)
#     This is exactly the silent-wrong class fixed in PR #129 (SSBOs were emitted
#     as `device T* name` then accessed with `.`).
#
# Add new invariants here as new silent-wrong classes are found. Exit non-zero on
# any violation so the sweep can gate. Run: `just msl-lint`.
set -uo pipefail
cd "$(dirname "$0")/.."

CLI="zig-out/bin/glslpp.exe"
[ -x "$CLI" ] || CLI="zig-out/bin/glslpp"
if [ ! -x "$CLI" ]; then echo "build first: mise exec -- zig build" >&2; exit 2; fi

SUITES="tests/spirv-cross tests/glslang-430 tests/ghostty tests/compute tests/conformance/stress"
# Relative path under the repo: the Windows glslpp.exe cannot write a Git-Bash
# `/tmp/...` mktemp path, which silently made every emit "fail".
mkdir -p .zig-cache
TMP=".zig-cache/msl-invariant-sweep.msl"
ok=0; unsup=0; viol=0; violations=""

# Emit a violation report for one MSL file. Echoes offending lines (or nothing).
check_invariants() {
  local f="$1"
  # INV1: collect pointer-param names, then look for `name.` direct access.
  # A pointer param looks like `device T* name` / `constant T* name` /
  # `threadgroup T* name` (the `*` may hug the type or the name).
  awk '
    # Gather pointer param names from any line declaring them.
    {
      line=$0
      while (match(line, /(device|constant|threadgroup)[ \t]+[A-Za-z_][A-Za-z0-9_:<> ]*\*[ \t]*([A-Za-z_][A-Za-z0-9_]*)/, m)) {
        ptr[m[2]]=1
        line=substr(line, RSTART+RLENGTH)
      }
    }
    { lines[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) {
        for (name in ptr) {
          # Direct `name.` (dot) access — invalid on a pointer. Exclude
          # `name[...]` (indexed-then-member is fine) and `(*name)` (deref).
          if (match(lines[i], "(^|[^A-Za-z0-9_.>])" name "\\.")) {
            # The declaration line itself can contain `name` but not `name.`,
            # so this only fires on real uses.
            printf "    INV1 pointer-dot: %s used as `%s.` (line %d): %s\n", name, name, i, lines[i]
          }
        }
      }
    }
  ' "$f"
}

for dir in $SUITES; do
  [ -d "$dir" ] || continue
  while IFS= read -r f; do
    st=fragment
    case "$f" in *.vert) st=vertex;; *.comp) st=compute;; esac
    if ! "$CLI" msl "$f" --stage "$st" -o "$TMP" 2>/dev/null; then
      unsup=$((unsup+1)); continue
    fi
    report="$(check_invariants "$TMP")"
    if [ -n "$report" ]; then
      viol=$((viol+1)); violations="${violations}${f}:\n${report}\n"
    else
      ok=$((ok+1))
    fi
  done < <(find "$dir" -type f \( -name '*.frag' -o -name '*.vert' -o -name '*.comp' \))
done

echo "=== MSL silent-wrong invariant sweep ==="
echo "OK:                  $ok"
echo "INVARIANT VIOLATIONS: $viol"
echo "honest-unsupported:  $unsup"
if [ "$viol" -gt 0 ]; then
  echo ""
  echo "--- violations (invalid MSL — silent-wrong) ---"
  printf "%b" "$violations"
  exit 1
fi
echo "All emitted MSL satisfies the invariants."
