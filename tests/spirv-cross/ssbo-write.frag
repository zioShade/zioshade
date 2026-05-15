#version 450

layout(binding = 0, std430) buffer SSBO
{
    vec4 data[4];
};

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    data[0].x += u;
    data[1].y += u * 2.0;
    data[2].z += u * 3.0;
    data[3].w += u * 4.0;
    fragColor = data[0] + data[1] + data[2] + data[3];
}
