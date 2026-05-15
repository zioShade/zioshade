#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Op test: min, max, clamp, saturate patterns
    float a = min(uv.x, uv.y);
    float b = max(uv.x, uv.y);
    float c = clamp(uv.x + uv.y, 0.0, 1.0);
    float d = min(max(uv.x * uv.y, 0.0), 1.0); // manual saturate
    fragColor = vec4(a, b, c, d);
}
