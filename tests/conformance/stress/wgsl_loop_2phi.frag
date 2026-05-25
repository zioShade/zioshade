// Tests: for loop with complex phi (2 variables updated)
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float sum = 0.0;
    float prod = 1.0;
    for (int i = 0; i < 10; i++) {
        float f = float(i) * 0.1 + 0.05;
        sum += f;
        prod *= f + 0.01;
        if (prod > 5.0) break;
    }
    fragColor = vec4(fract(sum), fract(prod), 0.0, 1.0);
}
