#version 450

layout(binding = 0) uniform Block {
    mat4 mvp;
    vec4 color;
    float intensity;
};

layout(location = 0) in vec4 position;
layout(location = 0) out vec4 fragColor;

void main()
{
    vec4 transformed = mvp * position;
    fragColor = transformed * color * intensity;
}
