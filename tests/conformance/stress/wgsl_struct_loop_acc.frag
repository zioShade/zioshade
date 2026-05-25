// Tests: for-loop with struct accumulation
#version 450
layout(location = 0) out vec4 fragColor;

struct Accum {
    float sum;
    float weight;
};

void main() {
    Accum a;
    a.sum = 0.0;
    a.weight = 0.0;

    for (int i = 0; i < 8; i++) {
        float w = 1.0 / (float(i) + 1.0);
        a.sum += w * fract(sin(float(i)) * 43758.5453);
        a.weight += w;
    }

    float result = a.sum / a.weight;
    fragColor = vec4(vec3(result), 1.0);
}
