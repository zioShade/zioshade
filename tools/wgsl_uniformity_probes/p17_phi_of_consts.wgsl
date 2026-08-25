// Uniformity probe p17_phi_of_consts: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a local assigned a different constant on each arm of a NON-uniform if (the
//   WGSL spelling of a phi of constants) is a NON-uniform value: branching on it
//   diverges, so the sample inside that branch is non-uniform
// CITED BY: the phi/store rule (p17 vs p24)
// EXPECTED VERDICT: REJECT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var x = 0.0;
    if (fc.x > 8.0) { x = 1.0; }
    var c = vec4f(0.0);
    if (x > 0.5) { c = textureSample(tex, smp, fc.xy); }
    return c;
}
