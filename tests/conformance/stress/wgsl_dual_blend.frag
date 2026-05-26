// Test: dual-source blending output
#version 450

layout(location = 0) out vec4 fragColor;
layout(location = 1) out vec4 fragBlend;

void main() {
    vec4 color = vec4(0.5, 0.3, 0.7, 1.0);
    fragColor = color;
    fragBlend = vec4(color.a, 0.0, 0.0, 0.0);
}
