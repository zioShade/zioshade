// Uniformity probe p24_phi_uniform_edge: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a local assigned on both arms of a UNIFORM if stays a uniform value (the
//   counterpart of p17), so the branch on it does not diverge and the sample
//   inside stays implicit
// CITED BY: the phi/store rule (p17 vs p24)
// EXPECTED VERDICT: ACCEPT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c: vec4f;
    var x = 0.0;
    if (globals.flag > 0.5) { x = 1.0; }
    if (x > 0.5) { c = textureSample(tex, smp, fc.xy); } else { c = vec4f(0.0); }
    return c;
}
