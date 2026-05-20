#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x * 0.01;
    float sum = 0.0;
    float term = x;
    int i = 0;
    do {
        sum += term;
        term *= -x * x / float((2 * i + 2) * (2 * i + 3));
        i++;
    } while (abs(term) > 0.001 && i < 20);
    fragColor = vec4(sum * 0.5 + 0.5);
}
