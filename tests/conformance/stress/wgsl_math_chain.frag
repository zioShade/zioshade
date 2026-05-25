// Tests: pow, exp, log, sqrt chain
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.5;
    float a = pow(x, 2.0);
    float b = exp(x) - 1.0;
    float c = log(x + 1.0);
    float d = sqrt(x);
    float result = a + b + c + d;
    fragColor = vec4(vec3(fract(result)), 1.0);
}
