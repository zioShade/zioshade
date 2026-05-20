#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    // Bool to int conversions
    bool a = x > 100.0;
    bool b = y > 100.0;
    int ai = int(a);
    int bi = int(b);
    int sum = ai + bi;
    // Bool to float
    float af = float(a);
    float bf = float(b);
    // Bool arithmetic
    float result = af + bf * 2.0;
    fragColor = vec4(float(sum) * 0.33, result * 0.33, 0.0, 1.0);
}
