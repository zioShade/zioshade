#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test shadowing and scoping
    float x = uv.x;
    {
        float x = uv.y;
        float y = x * 2.0;
        fragColor = vec4(y, 0.0, 0.0, 1.0);
    }
    fragColor += vec4(x, x, x, 0.0) * 0.5;
}
