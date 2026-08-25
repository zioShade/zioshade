// Uniformity probe p04_uniform_if: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a branch on a value read from var<uniform> (globals.flag) does NOT diverge
//   flow: the sample inside the arm stays implicit
// CITED BY: the value-seed rule: a uniform-buffer member read is a uniform value
// EXPECTED VERDICT: ACCEPT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c: vec4f;
    if (globals.flag > 0.5) { c = textureSample(tex, smp, fc.xy); } else { c = vec4f(0.0); }
    return c;
}
