// Tests: sequential store and load from same variable
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.5;
    x = x + 0.1;
    x = x * 2.0;
    x = x - 0.3;
    float y = x;
    y += 0.1;
    fragColor = vec4(x, y, x + y, 1.0);
}
