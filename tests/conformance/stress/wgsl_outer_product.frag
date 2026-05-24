#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test outer product (matrix from vector * vector)
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(0.3, 0.7, uv.x + uv.y);
    mat3 m = mat3(a.x * b.x, a.x * b.y, a.x * b.z,
                  a.y * b.x, a.y * b.y, a.y * b.z,
                  a.z * b.x, a.z * b.y, a.z * b.z);
    float det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]);
    vec3 color = vec3(abs(det) * 0.1);
    fragColor = vec4(color, 1.0);
}
