# CTS ingestion corpus — GraphicsFuzz (vendored from SPIRV-Tools)

Vendored SPIR-V corpus for `tools/cts_ingestion_sweep.sh` (`just cts-ingestion`), the
broad-corpus credibility sweep (r2d.2).

- **Source:** `test/fuzzers/corpora/spv` from [KhronosGroup/SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) — the reference validator's own fuzz seed corpus.
- **Pinned commit:** `a9cdf5bdd25d516294b5c25502b67e6116ed7eb5`
- **License:** Apache-2.0 (SPIRV-Tools). Vendored into zioshade under that license.
- **Contents:** 88 GraphicsFuzz structured-fuzz shaders (`.spv`), 87 spirv-val valid + 1 invalid.

These are real, broad-variety SPIR-V modules (adversarial nesting, edge-case constructs) —
exactly the ingestion-robustness surface the e54.4 mandate targets. The as-written r2d.2
target ("Vulkan CTS spirv_assembly") is inline text in dEQP C++ test programs, not a
standalone `.spv` corpus; this GraphicsFuzz set is the credible, cleanly-obtainable stand-in
(the harness is corpus-agnostic — any `.spv` corpus slots in via the dir argument).

## Refresh

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/KhronosGroup/SPIRV-Tools.git /tmp/st
cd /tmp/st && git sparse-checkout set test/fuzzers/corpora/spv
cp test/fuzzers/corpora/spv/*.spv <zioshade>/tests/cts/graphicsfuzz/
```

Update the pinned commit above and re-baseline `tests/cts/baseline.txt` (run
`tools/cts_ingestion_sweep.sh`, set the per-backend crash counts to the new values).
