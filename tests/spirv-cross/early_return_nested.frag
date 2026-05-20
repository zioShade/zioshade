#version 310 es
precision highp float;
out vec4 fragColor;

float check(float x) {
    if (x < 50.0) return 0.1;
    if (x < 100.0) return 0.3;
    if (x < 150.0) return 0.5;
    if (x < 200.0) return 0.7;
    return 0.9;
}

float nested(float a, float b) {
    if (a > 0.5) {
        if (b > 0.5) return 1.0;
        return 0.5;
    }
    if (b > 0.3) return 0.3;
    return 0.0;
}

void main() {
    float x = gl_FragCoord.x;
    float a = check(x);
    float b = nested(a, x * 0.01);
    fragColor = vec4(a, b, 0.0, 1.0);
}
