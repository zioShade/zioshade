#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test integer comparison and logical ops
void main() {
    int a = int(uv.x * 10.0);
    int b = int(uv.y * 10.0);
    bool above = a > 5;
    bool below = b < 3;
    bool either = above || below;
    bool both = above && below;
    float r = either ? 1.0 : 0.0;
    float g = both ? 1.0 : 0.0;
    fragColor = vec4(r, g, 0.0, 1.0);
}
