// Tests: float precision edge cases
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float eps = 0.0001;
    float big = 1000000.0;
    float result = (big + eps) - big;
    float inf_check = 1.0 / eps;
    fragColor = vec4(result, min(inf_check, 1.0), eps, 1.0);
}
