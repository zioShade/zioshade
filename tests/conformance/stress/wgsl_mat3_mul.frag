// Tests: matrix-vector multiply, transpose
#version 450
uniform float u_time;

void main() {
    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, cos(u_time), sin(u_time),
        0.0, -sin(u_time), cos(u_time)
    );
    vec3 v = vec3(0.5, 0.5, 0.5);
    vec3 r = m * v;
    gl_FragColor = vec4(r, 1.0);
}
