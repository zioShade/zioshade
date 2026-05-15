#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test multiple return from function
    float a = pow(u, 2.0);
    float b = exp(u);
    float c = log(max(u, 0.001));
    float d = sqrt(max(u, 0.0));
    float e = inversesqrt(max(u, 0.001));
    fragColor = vec4(a, b, c, d + e);
}
