#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Complex boolean logic
    bool a = uv.x > 0.3;
    bool b = uv.y > 0.5;
    bool c = uv.x < 0.7;
    bool d = uv.y < 0.8;

    bool and_result = a && b;
    bool or_result = c || d;
    bool xor_result = a != c;
    bool complex = (a && !b) || (c && d);

    float r = and_result ? 1.0 : 0.0;
    float g = or_result ? 1.0 : 0.0;
    float bval = complex ? 1.0 : 0.0;

    fragColor = vec4(r, g, bval, 1.0);
}
