#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test math builtins: abs, sign, floor, ceil, fract, mod, min, max
    float v = u * 10.0 - 5.0;
    float a = abs(v);
    float s = sign(v);
    float f = floor(v);
    float c = ceil(v);
    float fr = fract(v);
    float m = mod(v, 3.0);
    float mn = min(v, 2.0);
    float mx = max(v, -2.0);
    fragColor = vec4(a + s, f + c, fr + m, mn + mx);
}
