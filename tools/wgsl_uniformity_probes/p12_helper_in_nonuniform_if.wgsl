// Uniformity probe p12_helper_in_nonuniform_if: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   the same helper called only from inside a diverged arm is gated: its entry
//   flow is the call site block flow
// CITED BY: the interprocedural entry-flow rule (p11/p12)
// EXPECTED VERDICT: REJECT
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
fn samp(p: vec2f) -> vec4f { return textureSample(tex, smp, p); }
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    var c: vec4f;
    if (fc.x > 8.0) { c = samp(fc.xy); } else { c = vec4f(0.0); }
    return c;
}
