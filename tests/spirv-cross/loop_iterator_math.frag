#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x * 0.01;
    float taylor = 0.0;
    float term = x;
    for (int i = 1; i <= 10; i++) {
        taylor += term;
        term *= -x / float(i + 1);
    }
    fragColor = vec4(taylor * 0.5 + 0.5);
}
