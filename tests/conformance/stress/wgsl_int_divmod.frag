// Tests: integer modulo and division patterns
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    int a = 17;
    int b = 5;
    int q = a / b;
    int r = a % b;
    int neg = -a;
    float result = float(q) + float(r) * 0.1 + float(neg) * 0.01;
    fragColor = vec4(vec3(fract(result)), 1.0);
}
