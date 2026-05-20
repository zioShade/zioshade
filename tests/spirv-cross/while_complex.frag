#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x * 0.01;
    float acc = 1.0;
    int i = 0;
    while (acc > 0.01 && i < 20) {
        acc *= x;
        i++;
    }
    float y = gl_FragCoord.y * 0.01;
    float sum = 0.0;
    while (sum < 1.0) {
        sum += y * 0.1;
        if (sum > 0.8) break;
    }
    fragColor = vec4(acc, sum, float(i) * 0.05, 1.0);
}
