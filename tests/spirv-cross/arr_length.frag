#version 450

float arr[5];

void main() {
    int n = arr.length();
    gl_FragColor = vec4(float(n) / 10.0, 0.0, 0.0, 1.0);
}
