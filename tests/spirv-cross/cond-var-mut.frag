#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Minimal reproduction: conditional variable mutation
void main() {
    float x = uv.x;
    float row = floor(uv.y * 5.0);
    if (mod(row, 2.0) > 0.5) {
        x += 0.5;
    }
    float result = fract(x * 4.0);
    fragColor = vec4(result, 0.0, 0.0, 1.0);
}
