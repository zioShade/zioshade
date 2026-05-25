// Tests: global constant and uniform interaction
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_time;
const float PI = 3.14159265;

void main() {
    float angle = u_time * PI;
    float s = sin(angle);
    float c = cos(angle);
    vec2 rotated = vec2(c * 0.5, s * 0.5) + 0.5;
    fragColor = vec4(rotated.x, rotated.y, abs(s), 1.0);
}
