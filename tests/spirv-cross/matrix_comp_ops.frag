#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    mat3 a = mat3(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
    mat3 b = mat3(9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0);
    // Component-wise matrix ops
    mat3 sum = a + b;
    mat3 diff = a - b;
    mat3 scaled = a * 2.0;
    // Matrix multiply
    mat3 prod = a * b;
    // Scalar multiply on result
    vec3 v = prod * vec3(1.0);
    fragColor = vec4(v, 1.0) * 0.1;
}
