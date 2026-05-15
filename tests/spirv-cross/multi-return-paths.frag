#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test multiple return paths
    float x = uv.x;
    float y = uv.y;
    if (x < 0.25) {
        fragColor = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }
    if (x < 0.5) {
        fragColor = vec4(0.0, 1.0, 0.0, 1.0);
        return;
    }
    if (x < 0.75) {
        fragColor = vec4(0.0, 0.0, 1.0, 1.0);
        return;
    }
    fragColor = vec4(y, y, y, 1.0);
}
