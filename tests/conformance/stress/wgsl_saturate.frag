// Tests: clamp, saturate, and range operations
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float a = clamp(u_val, 0.0, 1.0);
    float b = saturate(u_val * 2.0 - 0.5);
    float c = min(max(u_val, -1.0), 1.0);
    float d = clamp(abs(u_val - 0.5) * 3.0, 0.0, 1.0);
    fragColor = vec4(a, b, c, d);
}
