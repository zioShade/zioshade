#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test complex swizzle + vector math
    vec4 a = vec4(uv, 0.0, 1.0);
    vec4 b = a.wzyx;
    vec4 c = a + b;
    vec2 d = c.xy * c.zw;
    float e = dot(d, vec2(1.0, 2.0));
    vec3 f = vec3(a.x, b.y, c.z);
    fragColor = vec4(f * e, 1.0);
}
