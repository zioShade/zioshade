// Tests: matrix passed as function parameter and returned
#version 450
layout(location = 0) out vec4 fragColor;

mat2 scale2x2(mat2 m, float s) {
    return mat2(m[0] * s, m[1] * s);
}

void main() {
    mat2 base = mat2(1.0, 2.0, 3.0, 4.0);
    mat2 scaled = scale2x2(base, 0.5);
    float det = scaled[0][0] * scaled[1][1] - scaled[0][1] * scaled[1][0];
    fragColor = vec4(vec3(abs(det)), 1.0);
}
