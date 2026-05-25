// Tests: negative numbers and sign operations
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = -0.5;
    float b = -a;
    float c = abs(a) + abs(b);
    float d = sign(a);
    float e = sign(b);
    fragColor = vec4(c, d + 0.5, e + 0.5, 1.0);
}
