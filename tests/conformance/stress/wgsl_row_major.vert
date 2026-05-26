// Test: layout qualifier with row_major matrices
#version 450

layout(binding = 0, row_major) uniform Matrices {
    mat4 world;
    mat4 viewProj;
    vec3 cameraPos;
    float pad;
};

layout(location = 0) in vec3 aPosition;
layout(location = 0) out vec3 vWorldPos;

void main() {
    vec4 worldPos = world * vec4(aPosition, 1.0);
    gl_Position = viewProj * worldPos;
    vWorldPos = worldPos.xyz;
}
