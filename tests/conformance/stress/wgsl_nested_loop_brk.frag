// Tests: nested for loops with break and continue
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float sum = 0.0;
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            if (x == y) continue;
            float val = float(x * 8 + y) * 0.01;
            sum += val;
            if (sum > 2.0) break;
        }
        if (sum > 2.0) break;
    }
    fragColor = vec4(vec3(fract(sum)), 1.0);
}
