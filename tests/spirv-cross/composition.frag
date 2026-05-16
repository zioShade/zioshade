#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float add(float a, float b) { return a + b; }
float mul(float a, float b) { return a * b; }
float clamp01(float x) { return clamp(x, 0.0, 1.0); }

void main()
{
    // Function composition chain
    float a = add(uv.x, uv.y);
    float b = mul(a, 2.0);
    float c = clamp01(b);
    float d = add(mul(c, 3.0), 0.5);
    float e = clamp01(d);

    fragColor = vec4(c, e, a, 1.0);
}
