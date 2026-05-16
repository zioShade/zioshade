#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Deeply nested if-else with mixed returns and assignments
    float r = 0.0;
    float g = 0.0;
    if (uv.x > 0.5) {
        if (uv.y > 0.5) {
            r = 1.0;
            g = uv.x * uv.y;
        } else {
            r = uv.x;
            g = 0.5;
        }
    } else {
        if (uv.y > 0.3) {
            r = 0.3;
            g = uv.y;
        } else {
            r = uv.x + uv.y;
            g = 1.0 - uv.x;
        }
    }
    fragColor = vec4(r, g, 0.5, 1.0);
}
