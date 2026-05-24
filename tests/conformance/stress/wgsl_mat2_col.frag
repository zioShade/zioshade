#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test matrix column access and construction
void main() {
    mat2 m = mat2(1.0, 2.0, 3.0, 4.0);
    vec2 col0 = m[0];
    vec2 col1 = m[1];
    float det = col0.x * col1.y - col0.y * col1.x;
    vec2 result = vec2(det) * uv;
    fragColor = vec4(result, 0.0, 1.0);
}
