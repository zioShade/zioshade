#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Smooth step chain with different thresholds
    float s1 = smoothstep(0.0, 0.3, uv.x);
    float s2 = smoothstep(0.3, 0.6, uv.x);
    float s3 = smoothstep(0.6, 1.0, uv.x);

    float r = mix(s1, s2, uv.y);
    float g = mix(s2, s3, uv.y);
    float b = mix(s1, s3, 1.0 - uv.y);

    fragColor = vec4(r, g, b, 1.0);
}
