#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Smooth minimum for organic blending of SDF circles
    float circle1 = length(uv - vec2(0.3, 0.5)) - 0.2;
    float circle2 = length(uv - vec2(0.7, 0.5)) - 0.2;

    // Manual smooth min
    float k = 0.1;
    float h = max(k - abs(circle1 - circle2), 0.0) / k;
    float smin_val = min(circle1, circle2) - h * h * k * 0.25;

    float shape = 1.0 - smoothstep(0.0, 0.01, smin_val);
    fragColor = vec4(vec3(shape), 1.0);
}
