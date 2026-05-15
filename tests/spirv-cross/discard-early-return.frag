#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test discard and early return patterns
    if (uv.x < 0.1 || uv.x > 0.9) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    if (uv.y < 0.1) discard;
    float r = smoothstep(0.1, 0.9, uv.x);
    float g = smoothstep(0.1, 0.9, uv.y);
    fragColor = vec4(r, g, 0.5, 1.0);
}
