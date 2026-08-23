#version 430 core
// Minimal repro of the zioshade-8k2 shape: textureSample reached from NON-UNIFORM
// control flow (an early return inside a conditional). naga ACCEPTS the WGSL
// zioshade emits for this shape, so every text gate and the naga round-trip
// render proxy pass; Chrome/tint REJECT it at pipeline build ("must only be
// called from uniform control flow") and the wintty.io player silently fell
// back to black. The browser oracle must report this fixture as REJECT with
// the tint message verbatim.
layout(location = 0) out vec4 fragColor;
layout(binding = 0) uniform sampler2D iChannel0;

void main() {
    if (gl_FragCoord.x < 128.0) {
        fragColor = texture(iChannel0, gl_FragCoord.xy / 256.0);
        return;
    }
    fragColor = vec4(0.2, 0.4, 0.6, 1.0);
}
