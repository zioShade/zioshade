// Tests: conditional loop exit with stored result
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

float search(float target) {
    float x = 0.0;
    float best = 100.0;
    for (int i = 0; i < 50; i++) {
        float candidate = float(i) * 0.1;
        float diff = abs(candidate - target);
        if (diff < best) {
            best = diff;
            x = candidate;
        }
        if (best < 0.05) break;
    }
    return x;
}

void main() {
    float r = search(u_val);
    fragColor = vec4(vec3(r), 1.0);
}
