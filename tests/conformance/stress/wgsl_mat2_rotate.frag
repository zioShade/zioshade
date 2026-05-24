// Tests: matrix operations in WGSL
#version 450
uniform float u_time;

void main() {
    mat2 m = mat2(1.0);
    float angle = u_time * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    mat2 rot = mat2(c, -s, s, c);
    vec2 p = rot * vec2(0.5, 0.5);
    gl_FragColor = vec4(p.x + 0.5, p.y + 0.5, 0.0, 1.0);
}
