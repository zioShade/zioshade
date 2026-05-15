#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector construction from mixed scalar/vector
    float a = uv.x;
    vec2 b = vec2(a, 1.0 - a);
    vec3 c = vec3(b, uv.y);
    vec4 d = vec4(c.x, c.y, c.z, 1.0);
    vec4 e = vec4(d.x + 0.1, d.y, d.z, d.w);
    fragColor = e;
}
