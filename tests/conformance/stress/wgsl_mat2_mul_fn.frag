// Tests: matrix multiplication with function
#version 450
layout(location = 0) out vec4 fragColor;

mat2 mulMat2(mat2 a, mat2 b) {
    return mat2(
        a[0][0] * b[0][0] + a[1][0] * b[0][1],
        a[0][0] * b[1][0] + a[1][0] * b[1][1],
        a[0][1] * b[0][0] + a[1][1] * b[0][1],
        a[0][1] * b[1][0] + a[1][1] * b[1][1]
    );
}

void main() {
    mat2 a = mat2(1.0, 2.0, 3.0, 4.0);
    mat2 b = mat2(0.5, -0.5, 1.0, 0.0);
    mat2 c = mulMat2(a, b);
    float det = c[0][0] * c[1][1] - c[0][1] * c[1][0];
    fragColor = vec4(vec3(abs(det) * 0.1), 1.0);
}
