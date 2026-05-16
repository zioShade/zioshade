#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Multiple early returns from different branches
    if (uv.x > 0.8) {
        fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }
    if (uv.y > 0.7) {
        fragColor = vec4(0.0, 1.0, 0.0, 1.0);
        return;
    }
    float r = sin(uv.x * 6.28) * 0.5 + 0.5;
    float g = cos(uv.y * 6.28) * 0.5 + 0.5;
    fragColor = vec4(r, g, 0.5, 1.0);
}
