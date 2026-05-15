#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Hexagonal grid pattern
    vec2 s = vec2(1.0, 1.732);
    vec2 h = s * 0.5;
    vec2 a = mod(uv, s) - h;
    vec2 b = mod(uv + h, s) - h;
    float d = min(dot(a, a), dot(b, b));
    float hex = smoothstep(0.2, 0.25, d);
    vec3 color = mix(vec3(0.9, 0.7, 0.3), vec3(0.1, 0.2, 0.4), hex);
    fragColor = vec4(color, 1.0);
}
