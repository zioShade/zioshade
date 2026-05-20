#version 310 es
precision highp float;
out vec4 fragColor;

float counter = 0.0;

float increment() {
    counter += 1.0;
    return counter;
}

void main() {
    float a = increment();
    float b = increment();
    float c = increment();
    fragColor = vec4(a * 0.1, b * 0.1, c * 0.1, 1.0);
}
