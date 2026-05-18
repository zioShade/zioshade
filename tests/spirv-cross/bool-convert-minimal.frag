#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Minimal bool(int) conversion test
void main() {
    int i = int(uv.x * 5.0);
    bool b = bool(i);
    float f = b ? 1.0 : 0.0;
    fragColor = vec4(f, f, f, 1.0);
}
