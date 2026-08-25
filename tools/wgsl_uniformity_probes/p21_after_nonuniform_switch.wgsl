// Uniformity probe p21_after_nonuniform_switch: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   after a switch on a NON-uniform selector merges, flow RECONVERGES: the
//   post-switch sample stays implicit; contrast the in-case sample of p14
// CITED BY: the post-switch reconvergence keep
// EXPECTED VERDICT: ACCEPT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c = vec4f(0.0);
    switch (u32(fc.x) & 3u) {
        case 1: { c = vec4f(0.1); }
        default: {}
    }
    return textureSample(tex, smp, fc.xy) + c;
}
