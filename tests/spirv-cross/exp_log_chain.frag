#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x * 0.01 + 0.1;
    float y = gl_FragCoord.y * 0.01 + 0.1;
    // Exp/log chains
    float a = exp(x);
    float b = log(a);
    float c = exp2(y);
    float d = log2(c);
    float e = pow(x, y);
    float f = sqrt(e);
    float g = inversesqrt(max(f, 0.001));
    fragColor = vec4(b / x, d / y, g, 1.0);
}
