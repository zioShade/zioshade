#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test matrix-vector ops with multiple matrices
    mat2 rot90 = mat2(0.0, 1.0, -1.0, 0.0);
    mat2 scale = mat2(2.0, 0.0, 0.0, 2.0);
    mat2 combined = scale * rot90;
    vec2 p = combined * uv;
    float r = length(p - vec2(1.0));
    float g = length(rot90 * uv);
    fragColor = vec4(r * 0.3, g * 0.2, length(uv) * 0.5, 1.0);
}
