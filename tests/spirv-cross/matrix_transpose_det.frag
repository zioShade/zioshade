#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float t = gl_FragCoord.x * 0.01;
    mat3 m = mat3(
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
        7.0, 8.0, 10.0
    );
    mat3 mt = transpose(m);
    float d = determinant(m);
    // Multiply transpose by original
    mat3 product = mt * m;
    vec3 diag = vec3(product[0][0], product[1][1], product[2][2]);
    fragColor = vec4(diag * 0.01, d * 0.01);
}
