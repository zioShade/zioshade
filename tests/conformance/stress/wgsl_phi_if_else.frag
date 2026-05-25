// Tests: phi node with both if and else branches
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.5;
    float y;
    if (x > 0.3) {
        y = x * 2.0;
    } else {
        y = x * 0.5;
    }
    fragColor = vec4(vec3(y), 1.0);
}
