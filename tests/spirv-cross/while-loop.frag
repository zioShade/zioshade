#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test while loop
    float x = uv.x;
    int iterations = 0;
    while (x > 0.01 && iterations < 10) {
        x = x * 0.5;
        iterations++;
    }
    fragColor = vec4(x, float(iterations) / 10.0, 0.0, 1.0);
}
