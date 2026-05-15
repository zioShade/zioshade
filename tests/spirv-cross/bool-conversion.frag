#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test bool to float conversion chains
    bool a = uv.x > 0.5;
    bool b = uv.y > 0.5;
    float fa = float(a);
    float fb = float(b);
    bool c = a && b;
    bool d = a || b;
    float fc = float(c);
    float fd = float(d);
    fragColor = vec4(fa, fb, fc, fd);
}
