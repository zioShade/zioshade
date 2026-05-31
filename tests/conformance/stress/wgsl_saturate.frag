// Tests: clamp, saturate, and range operations
#version 450
layout(location = 0) out vec4 fragColor;
layout(location = 0) in float u_val;

void main() {
    float a = clamp(u_val, 0.0, 1.0);
    float b = clamp(u_val * 2.0 - 0.5, 0.0, 1.0);
    float c = min(max(u_val, -1.0), 1.0);
    float d = clamp(abs(u_val - 0.5) * 3.0, 0.0, 1.0);
    fragColor = vec4(a, b, c, d);
}
