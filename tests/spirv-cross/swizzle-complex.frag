#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test vector swizzle and component access
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    vec3 b = a.xyz;
    vec2 c = a.zw;
    float d = a.w;
    vec4 e = c.xyyx;
    vec3 f = b.zyx;
    fragColor = vec4(b.x + c.y, f.z, d, e.x);
}
