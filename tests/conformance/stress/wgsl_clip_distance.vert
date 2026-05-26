// Test: gl_ClipDistance output
#version 450

layout(location = 0) in vec3 aPosition;
layout(location = 1) in vec2 aTexCoord;

layout(binding = 0) uniform UBO {
    mat4 mvp;
    vec4 clipPlane;
};

layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = mvp * vec4(aPosition, 1.0);
    gl_ClipDistance[0] = dot(vec4(aPosition, 1.0), clipPlane);
    vTexCoord = aTexCoord;
}
