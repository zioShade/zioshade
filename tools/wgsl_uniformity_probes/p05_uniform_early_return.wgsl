// Uniformity probe p05_uniform_early_return: WGSL uniformity prepass tint-evidence
// corpus (issue #691). A self-contained WGSL module whose accept/reject
// by tint (Chrome for Testing + Dawn) is the empirical basis for one rule
// of src/wgsl_uniformity.zig. Probed 2026-08-24; re-run: the
// wgsl-uniformity-probes just recipe (a ZWB_OVERRIDE_DIR sweep of this
// directory through tools/wgsl_browser_check.mjs).
// RULE EVIDENCED:
//   an early return selected by a UNIFORM condition (globals.flag) leaves the
//   continuation in uniform flow, so the sample after it stays implicit; the
//   counterpart of p03 with a uniform condition
// CITED BY: the flow rule, alongside p03
// EXPECTED VERDICT: ACCEPT
// NOTE: under the harness uniform state Globals.flag reads 256.0, so the
// early-return arm is always taken and this probe renders ALL BLACK: in the
// no-reference liveness mode it reports FAIL-black, which is PINNED in
// tools/wgsl_browser_baseline.txt. The verdict that matters here is tint
// ACCEPT, proved by the absence of a REJECT.
struct Globals { flag: f32, res: vec3f }
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> globals: Globals;
@group(0) @binding(2) var smp: sampler;
@fragment
fn main(@builtin(position) fc: vec4f) -> @location(0) vec4f {
    if (globals.flag > 0.5) { return vec4f(0.0); }
    return textureSample(tex, smp, fc.xy);
}
