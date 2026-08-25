// Uniformity probe p08_uniform_bound_loop: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a loop whose bound comes from the uniform buffer has a UNIFORM trip count, so
//   the in-loop sample stays implicit
// CITED BY: the p07 rule with a loaded (not literal) bound
// EXPECTED VERDICT: ACCEPT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c = vec4f(0.0);
    let n = i32(globals.flag);
    for (var i = 0; i < n; i = i + 1) { c = c + textureSample(tex, smp, fc.xy + vec2f(f32(i)) * 0.01); }
    return c;
}
