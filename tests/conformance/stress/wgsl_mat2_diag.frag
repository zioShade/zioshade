// Tests: matrix transpose and outer product
#version 450
uniform float u_val;

void main() {
    mat2 m = mat2(u_val, 0.0, 0.0, u_val);
    float d = m[0][0] + m[1][1];
    gl_FragColor = vec4(d, 0.0, 0.0, 1.0);
}
