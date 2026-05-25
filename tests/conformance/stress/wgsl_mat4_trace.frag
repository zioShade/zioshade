// Tests: mat4 inverse-like computation
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    mat4 m = mat4(
        2.0, 0.0, 0.0, 0.0,
        0.0, 3.0, 0.0, 0.0,
        0.0, 0.0, 4.0, 0.0,
        1.0, 2.0, 3.0, 1.0
    );
    float trace = m[0][0] + m[1][1] + m[2][2] + m[3][3];
    vec4 col3 = m[3];
    vec3 transformed = vec3(col3.x, col3.y, col3.z) / trace;
    fragColor = vec4(transformed * 0.25, 1.0);
}
