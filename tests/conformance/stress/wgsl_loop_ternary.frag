// Tests: loop with ternary inside expression
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        float v = float(i) * 0.1;
        sum += (v > u_val) ? v * 2.0 : v * 0.5;
    }
    fragColor = vec4(vec3(fract(sum)), 1.0);
}
