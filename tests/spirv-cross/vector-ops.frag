#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector construction and swizzling
    vec4 a = vec4(1.0, 0.0, 0.0, 1.0);
    vec4 b = vec4(0.0, 1.0, 0.0, 1.0);
    vec4 c = mix(a, b, uv.x);
    vec2 d = c.xy + c.zw;
    vec3 e = vec3(d, uv.y);
    fragColor = vec4(e, 1.0);
}
