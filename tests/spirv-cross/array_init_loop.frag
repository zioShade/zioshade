#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // Array initialized in a loop
    float arr[4];
    for (int i = 0; i < 4; i++) {
        arr[i] = float(i) * 0.25;
    }
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum += arr[i];
    }
    fragColor = vec4(sum);
}
