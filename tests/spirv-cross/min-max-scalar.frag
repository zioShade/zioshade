#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Min/max with scalar promotion
    vec3 a = vec3(uv.x * 2.0, uv.y * 3.0, uv.x + uv.y);
    vec3 b = max(a, 0.5);   // max(vec3, float) — scalar promotion
    vec3 c = min(b, 1.0);   // min(vec3, float) — scalar promotion
    vec3 d = clamp(a, 0.2, 0.8);  // clamp(vec3, float, float)

    fragColor = vec4(d, 1.0);
}
