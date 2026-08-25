// Uniformity probe p14_switch_nonuniform: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   a switch on a NON-uniform selector (u32(fc.x)) puts every case body in
//   non-uniform flow
// CITED BY: the WGSL emitter switch-case replay path
// EXPECTED VERDICT: REJECT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c = vec4f(0.0);
    switch (u32(fc.x) & 3u) {
        case 1: { c = textureSample(tex, smp, fc.xy); }
        default: {}
    }
    return c;
}
