// Tests: matrix operations (multiply, transpose, inverse)
#version 450
uniform float u_val;
uniform mat4 u_mat;

void main() {
    mat4 m = u_mat;
    mat4 identity = mat4(1.0);
    mat4 result = m * identity;
    vec4 v = result * vec4(1.0, 0.0, 0.0, 1.0);
    float x = v.x + u_val;
    gl_FragColor = vec4(x, v.y, v.z, 1.0);
}
