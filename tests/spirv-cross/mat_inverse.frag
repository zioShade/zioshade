#version 450

// Test matrix operations: transpose, inverse, outer product
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    mat2 m = mat2(
        1.0, 0.5,
        0.3, 0.8
    );
    mat2 t = transpose(m);
    float det = m[0][0] * m[1][1] - m[0][1] * m[1][0];
    float inv_det = 1.0 / det;
    mat2 inv = mat2(
        m[1][1] * inv_det, -m[0][1] * inv_det,
        -m[1][0] * inv_det, m[0][0] * inv_det
    );

    vec2 v = uv * 2.0 - 1.0;
    vec2 result = inv * v;

    gl_FragColor = vec4(result * 0.5 + 0.5, det, 1.0);
}
