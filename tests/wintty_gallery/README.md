# wintty shader gallery corpus (vendored)

This directory is a verbatim vendor of the [wintty](https://github.com/deblasis/wintty)
shader gallery: the custom post-process shaders real consumers select in the
terminal's Settings and that wintty compiles at runtime through zioshade
(GLSL -> SPIR-V -> HLSL/MSL/WGSL). It is vendored here so the compiler's
verification gates exercise the exact shapes a shipping consumer feeds it,
not just hand-written fixtures.

Every shader in this corpus shipped through wintty's own pipeline before it
landed here, and three silent-wrong bugs were found in it that no existing
zioshade gate caught (the uniform-derived global-initializer drop, the
early-return-in-mainImage WGSL black frame, and the store-sunk-into-branch
zero read). That is the case for vendoring it: these are the shapes real
shaders ship.

## Layout

- `<id>.frag` - one self-contained file per gallery shader, ready to compile
  as a fragment: `shadertoy_prefix.glsl + "\n" + <id>.glsl + "\n"` with
  nothing else prepended or rewritten. This is byte-for-byte the same recipe
  the wintty-website staging script (`scripts/stage-shaders.mjs`) uses, so
  what the gates see here is what the website playground and the terminal
  compile.
- `shaders.json` - the gallery manifest copied unmodified (ids, authors,
  licenses, upstream sources).
- `LICENSES/` - full license texts for the third-party entries.

## Provenance and licensing

Upstream: `windows/Ghostty/Assets/Shaders/` in the wintty repository, plus
the uniform contract `src/renderer/shaders/shadertoy_prefix.glsl`. The
upstream files are MIT or Unlicense; each `.glsl` carries its own provenance
header and the license texts are in `LICENSES/`. The `.frag` files here are
vendored verbatim (prefix + shader, no edits) so the corpus stays
byte-comparable with upstream.

| id | author | license | source |
| --- | --- | --- | --- |
| cursor_tail | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| cursor_sweep | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| ripple_cursor | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| ripple_rectangle_cursor | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| sonic_boom_cursor | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| rectangle_boom_cursor | Sahaj Bhatt | MIT | sahaj-b/ghostty-cursor-shaders |
| cursor_teleport | wintty project | MIT | wintty |
| lightning_strike | wintty project | MIT | wintty |
| scanline | zoitrok | Unlicense | zoitrok (see LICENSES/) |
| pixels | zoitrok | Unlicense | zoitrok (see LICENSES/) |
| crt | wintty | MIT | wintty |
| text_glow | wintty | MIT | wintty |
| snowfall | wintty | MIT | wintty |
| aurora_background | wintty | MIT | wintty |
| passthrough | ghostty | MIT | ghostty-org/ghostty |
| interference | wintty project | MIT | wintty |

## Gates that sweep this corpus

- `just wgsl-render` - WGSL render proxy over the corpus (via
  `tools/wgsl_render_check.sh`, wired into `just ci-full`), with the expected
  DIFFERs pinned in the tool's baseline file.
- `just wgsl-naga` and `just wgsl-tint` - WGSL text-validity sweeps
  (`tools/wgsl_naga_sweep.sh`, `tools/wgsl_tint_sweep.sh`).

## Resync

When the wintty gallery changes, re-vendor with the same recipe (run from a
wintty checkout; entries are `passthrough` plus everything in
`shaders.json`, deduplicated):

```sh
python3 - <<'EOF'
import json, shutil
from pathlib import Path
W = Path("/path/to/wintty")
S = W / "windows/Ghostty/Assets/Shaders"
prefix = (W / "src/renderer/shaders/shadertoy_prefix.glsl").read_text()
manifest = json.loads((S / "shaders.json").read_text())
out = Path("/path/to/zioshade/tests/wintty_gallery")
for e in [{"id": "passthrough", "file": "passthrough.glsl"}] + manifest["shaders"]:
    src = (S / e["file"]).read_text()
    (out / (e["id"] + ".frag")).write_text(prefix + "\n" + src + "\n")
shutil.copyfile(S / "shaders.json", out / "shaders.json")
EOF
```

Then re-run the gates above and refresh the render baseline per the
instructions in `tools/wgsl_render_check.sh`.
