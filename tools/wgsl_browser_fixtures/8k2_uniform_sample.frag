#version 430 core
// Minimal repro of the zioshade-8k2 shape: an implicit-Lod sample reached
// from NON-UNIFORM control flow (an early return inside a conditional).
// naga ACCEPTS the plain textureSample WGSL, so every text gate and the naga
// round-trip render proxy passed; Chrome/tint REJECTED it at shader-module
// build ("textureSample must only be called from uniform control flow") and
// the wintty.io player silently fell back to black. The WGSL backend now
// lowers exactly this shape to textureSampleLevel(..., 0.0), so the fixture
// must COMPILE, build a pipeline, and render: the browser oracle reports it
// PASS. (The uniform block at binding 1 mirrors the wintty player contract
// so the emitted bindings are texture b0 / uniform b1 / sampler b2, matching
// the harness bind group.)
layout(location = 0) out vec4 fragColor;
layout(binding = 0) uniform sampler2D iChannel0;
layout(binding = 1) uniform Globals { float iUnused; };

void main() {
    if (gl_FragCoord.x < 128.0) {
        fragColor = texture(iChannel0, gl_FragCoord.xy / 256.0);
        return;
    }
    fragColor = vec4(0.2, 0.4, 0.6, 1.0);
}
