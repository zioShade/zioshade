#version 450

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test mat4 construction and multiplication
    float f = v_color.x;
    mat4 m = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, f, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    );
    vec4 result = m * v_color;
    fragColor = result;
}
