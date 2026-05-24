// Tests: mat2 rotation
#version 450
uniform float u_angle;

void main() {
    float c = cos(u_angle);
    float s = sin(u_angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 p = rot * vec2(0.5, 0.5);
    gl_FragColor = vec4(p.x + 0.5, p.y + 0.5, 0.0, 1.0);
}
