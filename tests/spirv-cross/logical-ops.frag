#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test logical operations
    bool a = uv.x > 0.5;
    bool b = uv.y > 0.5;
    bool c = a && b;
    bool d = a || b;
    bool e = !a;
    fragColor = vec4(
        c ? 1.0 : 0.0,
        d ? 1.0 : 0.0,
        e ? 1.0 : 0.0,
        1.0
    );
}
