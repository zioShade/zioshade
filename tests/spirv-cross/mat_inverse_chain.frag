#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, 2.0, 0.0,
        0.0, 0.0, 3.0
    );
    mat3 mi = inverse(m);
    mat3 m2 = m * mi; // should be identity
    // Extract diagonal
    float d0 = m2[0][0];
    float d1 = m2[1][1];
    float d2 = m2[2][2];
    fragColor = vec4(d0, d1, d2, 1.0);
}
