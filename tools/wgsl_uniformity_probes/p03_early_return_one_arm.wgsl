// Uniformity probe p03_early_return_one_arm: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   one arm of a NON-uniform if returns early; the sample after the join executes
//   for a SUBSET of invocations, so the merge flow is non-uniform
// CITED BY: the flow rule: a merge reached by a SUBSET is non-uniform
// EXPECTED VERDICT: REJECT
// PROVENANCE: RECONSTRUCTED 2026-08-25 (issue #691) from the rule text that
// cites it; the original probing session's p03 file was lost with its scratch
// directory. The shape is the one the rule describes (early return in one arm
// of a non-uniform if, sample after the join) and matches
// tools/wgsl_browser_fixtures/8k2_uniform_sample.frag, whose header records
// tint rejecting exactly this un-lowered form.
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    if (fc.x > 8.0) { return vec4f(0.0); }
    return textureSample(tex, smp, fc.xy);
}
