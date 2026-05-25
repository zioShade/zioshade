// Tests: for loop with break and complex state
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float bestDist = 999.0;
    int bestIdx = -1;
    for (int i = 0; i < 20; i++) {
        float pos = float(i) * 0.05;
        float d = abs(pos - u_val);
        if (d < bestDist) {
            bestDist = d;
            bestIdx = i;
        }
        if (bestDist < 0.01) break;
    }
    float r = float(bestIdx) / 20.0;
    fragColor = vec4(r, bestDist, 0.0, 1.0);
}
