#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test power and logarithm functions
    float a = pow(uv.x, 2.0);
    float b = exp(uv.x * 3.0);
    float c = log(max(uv.y, 0.001));
    float d = exp2(uv.x);
    float e = log2(max(uv.y, 0.001) + 1.0);
    float f = sqrt(max(a + b, 0.0));
    float g = inversesqrt(max(c + 0.1, 0.001));
    fragColor = vec4(f, g, d, 1.0);
}
