// Tests: outerProduct and transpose
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 a = vec3(1.0, 2.0, 3.0);
    vec3 b = vec3(4.0, 5.0, 6.0);
    mat3 outer = mat3(
        a.x * b.x, a.x * b.y, a.x * b.z,
        a.y * b.x, a.y * b.y, a.y * b.z,
        a.z * b.x, a.z * b.y, a.z * b.z
    );
    float det_approx = outer[0][0] + outer[1][1] + outer[2][2];
    fragColor = vec4(vec3(det_approx * 0.1), 1.0);
}
