// Tests: phi with vec4 and multiple branches
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 color;
    float mode = 2.5;
    if (mode < 1.0) {
        color = vec4(1.0, 0.0, 0.0, 1.0);
    } else if (mode < 2.0) {
        color = vec4(0.0, 1.0, 0.0, 1.0);
    } else {
        color = vec4(0.0, 0.0, 1.0, 1.0);
    }
    fragColor = color;
}
