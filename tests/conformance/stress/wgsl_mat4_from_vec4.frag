// Tests: mat4 construction from 4 vec4
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 c0 = vec4(1.0, 0.0, 0.0, 0.0);
    vec4 c1 = vec4(0.0, 1.0, 0.0, 0.0);
    vec4 c2 = vec4(0.0, 0.0, 1.0, 0.0);
    vec4 c3 = vec4(0.5, 0.5, 0.0, 1.0);
    mat4 m = mat4(c0, c1, c2, c3);
    vec4 v = m * vec4(1.0, 1.0, 1.0, 1.0);
    fragColor = v;
}
