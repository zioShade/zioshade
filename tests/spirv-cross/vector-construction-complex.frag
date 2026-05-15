#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector construction from mixed scalar/vector (complex)
    vec3 c = vec3(uv, 0.0);
    vec4 d = vec4(c.xy, c.z, 1.0);
    vec4 e = vec4(d.x + 0.1, d.yzw);
    fragColor = e;
}
