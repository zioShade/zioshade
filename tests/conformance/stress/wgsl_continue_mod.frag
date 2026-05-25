// Tests: loop with continue and complex induction
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float sum = 0.0;
    for (int i = 0; i < 20; i++) {
        if (i % 5 == 0) continue;
        if (i % 7 == 0) continue;
        float val = float(i) / 100.0;
        val = val * val;
        sum += val;
    }
    fragColor = vec4(vec3(fract(sum * 10.0)), 1.0);
}
