// Test: multiple varying interpolation qualifiers
#version 450

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec2 aTexCoord;
layout(location = 3) in vec4 aColor;

layout(binding = 0) uniform UBO {
    mat4 mvp;
};

layout(location = 0) out vec3 vNormal;
layout(location = 1) out vec2 vUV;
layout(location = 2) out vec4 vColor;
layout(location = 3) out vec3 vWorldPos;

void main() {
    gl_Position = mvp * vec4(aPosition, 1.0);
    vNormal = aNormal;
    vUV = aTexCoord;
    vColor = aColor;
    vWorldPos = aPosition;
}
