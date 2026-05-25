#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    float a = u_val;
    if (a > 0.5) {
        fragColor = vec4(1.0, 0.0, 0.0, 1.0);
    } else {
        fragColor = vec4(0.0, 1.0, 0.0, 1.0);
    }
}
