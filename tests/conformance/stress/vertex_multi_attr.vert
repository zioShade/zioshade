// Tests: vertex shader with multiple inputs and outputs
#version 450

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aTexCoord;
layout(location = 2) in vec3 aNormal;

out vec2 vTexCoord;
out vec3 vNormal;
out vec3 vWorldPos;

uniform mat4 uMVP;
uniform mat4 uModel;

void main() {
    vec4 worldPos = uModel * vec4(aPosition, 1.0);
    vWorldPos = worldPos.xyz;
    vTexCoord = aTexCoord;
    vNormal = mat3(uModel) * aNormal;
    gl_Position = uMVP * vec4(aPosition, 1.0);
}
