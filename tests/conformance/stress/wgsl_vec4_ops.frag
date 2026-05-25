// Tests: vec4 component-wise operations
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 a = vec4(1.0, 2.0, 3.0, 4.0);
    vec4 b = vec4(0.5, 1.5, 2.5, 3.5);
    vec4 sum = a + b;
    vec4 diff = a - b;
    vec4 prod = a * b;
    vec4 quot = a / (b + 0.001);
    vec4 result = (sum + diff + prod + quot) * 0.0625;
    fragColor = result;
}
