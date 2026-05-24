#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test loop with break condition inside nested if
void main() {
    float sum = 0.0;
    int i = 0;
    while (i < 20) {
        float val = float(i) * 0.1;
        if (val > uv.x) {
            break;
        }
        sum += val;
        i = i + 1;
    }
    fragColor = vec4(sum, sum * uv.y, 0.0, 1.0);
}
