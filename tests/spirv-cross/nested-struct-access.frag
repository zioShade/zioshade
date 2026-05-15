#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested structures
    struct Inner {
        float a;
        vec2 b;
    };
    struct Outer {
        Inner i;
        float c;
    };
    Outer o;
    o.i.a = uv.x;
    o.i.b = vec2(uv.x, uv.y);
    o.c = uv.y;
    fragColor = vec4(o.i.a, o.i.b, o.c);
}
