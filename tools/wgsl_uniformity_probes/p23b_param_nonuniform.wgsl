// Uniformity probe p23b_param_nonuniform: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   the same helper whose only call site passes a NON-uniform argument (fc.x) has
//   that parameter poisoned, so the branch on it inside the helper diverges
// CITED BY: the parameter rule (p23a/p23b)
// EXPECTED VERDICT: REJECT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
fn samp(x: f32, p: vec2f) -> vec4f {
    if (x > 0.5) { return textureSample(tex, smp, p); }
    return vec4f(0.0);
}
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    return samp(fc.x, fc.xy);
}
