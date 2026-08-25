// Uniformity probe p09_varying_bound_loop: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a loop whose bound is derived from fc.x has a NON-uniform trip count, so the
//   in-loop sample is in non-uniform flow
// CITED BY: the loop-prelude rule (p07/p09) and the subset-merge list
// EXPECTED VERDICT: REJECT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c = vec4f(0.0);
    let n = i32(fc.x);
    for (var i = 0; i < n; i = i + 1) { c = c + textureSample(tex, smp, fc.xy + vec2f(f32(i)) * 0.01); }
    return c;
}
