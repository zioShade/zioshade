#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // 2D array operations
    float m[3][4];
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 4; j++) {
            m[i][j] = float(i * 4 + j) * 0.1;
        }
    }
    float sum = 0.0;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 4; j++) {
            sum += m[i][j];
        }
    }
    fragColor = vec4(sum * 0.1);
}
