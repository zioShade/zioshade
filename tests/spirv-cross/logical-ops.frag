#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test logical ops: &&, ||, !
    bool a = u > 0.3;
    bool b = u < 0.7;
    bool c = a && b;
    bool d = a || b;
    bool e = !a;
    float result = 0.0;
    if (c) result += 0.25;
    if (d) result += 0.25;
    if (e) result += 0.25;
    if (!c && d) result += 0.25;
    fragColor = vec4(result);
}
