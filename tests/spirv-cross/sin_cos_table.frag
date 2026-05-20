#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float angle = gl_FragCoord.x * 0.05;
    // Build a lookup table of sin/cos values
    float table[8];
    for (int i = 0; i < 8; i++) {
        table[i] = sin(angle + float(i) * 0.785);
    }
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        sum += table[i];
    }
    float avg = sum / 8.0;
    fragColor = vec4(avg * 0.5 + 0.5);
}
