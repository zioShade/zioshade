// Tests: for-loop with break and phi
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float result = 0.0;
    float last = 0.0;
    for (int i = 0; i < 20; i++) {
        float val = float(i) * 0.1;
        result += val;
        last = val;
        if (result > 3.0) break;
    }
    fragColor = vec4(fract(result), fract(last), 0.0, 1.0);
}
