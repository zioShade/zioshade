// Test: vertex with multiple output blocks and point size
#version 450

layout(location = 0) in vec3 aPos;
layout(location = 1) in vec4 aColor;
layout(location = 2) in vec2 aUV;

layout(binding = 0) uniform UBO {
    mat4 mvp;
    float pointSize;
};

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec2 vUV;

void main() {
    gl_Position = mvp * vec4(aPos, 1.0);
    gl_PointSize = pointSize;
    vColor = aColor;
    vUV = aUV;
}
