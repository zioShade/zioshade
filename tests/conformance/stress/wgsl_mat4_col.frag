// Tests: mat4 column access and modification
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    mat4 m = mat4(1.0);
    m[3] = vec4(2.0, 3.0, 4.0, 1.0);
    vec4 col3 = m[3];
    float det = m[0][0] + m[1][1] + m[2][2] + col3.w;
    fragColor = vec4(vec3(det * 0.1), 1.0);
}
