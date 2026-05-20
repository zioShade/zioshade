#version 310 es
precision highp float;
out vec4 fragColor;

float val = 0.0;
float bump() { val += 0.1; return val; }

void main() {
    float x = gl_FragCoord.x;
    float a = x > 100.0 ? bump() : 0.0;
    float b = x > 150.0 ? bump() : bump();
    float c = bump();
    fragColor = vec4(a, b, c, val);
}
