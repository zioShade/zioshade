#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float t = gl_FragCoord.x * 0.01;
    // Chain of matrix operations
    mat2 m1 = mat2(cos(t), -sin(t), sin(t), cos(t));
    mat2 m2 = mat2(2.0, 0.0, 0.0, 3.0);
    mat2 m3 = m1 * m2;
    vec2 v = vec2(0.5, 0.3);
    vec2 r1 = m3 * v;
    vec2 r2 = v * m3;
    // mat3 operations
    mat3 m4 = mat3(1.0);
    mat3 m5 = mat3(m1, vec2(0.0), vec2(0.0), 1.0);
    vec3 r3 = m4 * m5 * vec3(v, 1.0);
    fragColor = vec4(r1, r2);
}
