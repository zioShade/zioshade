#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mat3 construction and operations
void main() {
    mat3 m = mat3(1.0, 0.0, 0.0,
                  0.0, 1.0, 0.0,
                  0.0, 0.0, 1.0);
    vec3 v = vec3(uv.x, uv.y, 0.5);
    vec3 result = m * v;
    fragColor = vec4(result, 1.0);
}
