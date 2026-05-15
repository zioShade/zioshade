#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

// Test global constants
const float PI = 3.14159265;
const float TWO_PI = 6.28318530;
const float HALF_PI = 1.57079632;

void main()
{
    float angle = u * TWO_PI;
    float s = sin(angle);
    float c = cos(angle);
    float t = tan(angle * 0.5);
    fragColor = vec4(s * 0.5 + 0.5, c * 0.5 + 0.5, t, 1.0);
}
