// Tests: mat2 construction and multiplication
#version 450
uniform float u_angle;
uniform vec2 u_pos;

void main() {
    float c = cos(u_angle);
    float s = sin(u_angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 rotated = rot * u_pos;
    gl_FragColor = vec4(rotated.x, rotated.y, 0.0, 1.0);
}
