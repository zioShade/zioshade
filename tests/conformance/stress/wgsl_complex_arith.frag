// Tests: complex expression with many operators
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = 1.0;
    float b = 2.0;
    float c = 3.0;
    float d = 4.0;
    float result = (a + b) * (c - d) / (a * d + 0.001) + (b / c - a * 0.5);
    fragColor = vec4(vec3(fract(abs(result))), 1.0);
}
