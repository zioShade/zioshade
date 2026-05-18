#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Minimal gl_FragCoord test
void main() {
    vec2 fc = gl_FragCoord.xy / 800.0;
    fragColor = vec4(fc, 0.0, 1.0);
}
