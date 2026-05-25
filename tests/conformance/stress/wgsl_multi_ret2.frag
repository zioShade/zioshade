// Tests: multiple early returns from different code paths
#version 450
layout(location = 0) out vec4 fragColor;

float classify(float x) {
    if (x < 0.25) return 0.0;
    if (x < 0.5) return 1.0;
    if (x < 0.75) return 2.0;
    return 3.0;
}

void main() {
    float c = classify(0.6);
    fragColor = vec4(vec3(c / 3.0), 1.0);
}
