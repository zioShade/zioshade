// Tests: vertex shader with uniform matrix transform
#version 450
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
layout(location = 0) out vec3 vNormal;
layout(location = 1) out vec3 vWorldPos;
uniform mat4 u_model;
uniform mat4 u_viewProj;

void main() {
    vec4 worldPos = u_model * vec4(aPos, 1.0);
    vWorldPos = worldPos.xyz;
    vNormal = mat3(u_model) * aNormal;
    gl_Position = u_viewProj * worldPos;
}
