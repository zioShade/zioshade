#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test clamp, mix, step, smoothstep
    float a = clamp(uv.x, 0.2, 0.8);
    float b = mix(0.0, 1.0, uv.y);
    float c = step(0.5, uv.x);
    float d = smoothstep(0.2, 0.8, uv.y);
    vec2 e = clamp(uv, vec2(0.1), vec2(0.9));
    fragColor = vec4(a, b, c * d, e.x + e.y);
}
