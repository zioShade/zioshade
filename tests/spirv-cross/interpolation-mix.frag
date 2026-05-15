#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test mix, clamp, saturate patterns
    float a = mix(0.0, 1.0, u);
    float b = clamp(u * 2.0 - 0.5, 0.0, 1.0);
    float c = min(max(u, 0.0), 1.0);
    float d = step(0.5, u);
    fragColor = vec4(a, b, c, d);
}
