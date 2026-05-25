// Tests: function calling other function with conditional paths
#version 450
layout(location = 0) out vec4 fragColor;

float noise(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}

float pattern(float x, float y) {
    float n1 = noise(x);
    float n2 = noise(y);
    if (n1 > n2) {
        return n1 - n2;
    } else {
        return n2 - n1;
    }
}

void main() {
    float r = pattern(0.5, 0.3);
    float g = pattern(0.7, 0.9);
    fragColor = vec4(r, g, r + g, 1.0);
}
