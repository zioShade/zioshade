#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float t = gl_FragCoord.x * 0.01;
    mat4 m1 = mat4(1.0);
    mat4 m2 = mat4(
        cos(t), sin(t), 0.0, 0.0,
        -sin(t), cos(t), 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    );
    mat4 m3 = mat4(
        1.0, 0.0, 0.0, 0.5,
        0.0, 1.0, 0.0, 0.3,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    );
    mat4 result = m1 * m2 * m3;
    vec4 v = result * vec4(1.0, 0.0, 0.0, 1.0);
    fragColor = v;
}
