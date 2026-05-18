#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gl_FragCoord with operations
void main() {
    vec2 fc = gl_FragCoord.xy;
    float d = length(fc - vec2(400.0, 300.0));
    float ring = sin(d * 0.1) * 0.5 + 0.5;
    fragColor = vec4(ring, ring * 0.5, 1.0 - ring, 1.0);
}
