// Tests: multiple uniforms of different types
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_float;
uniform int u_int;
uniform vec3 u_vec3;
uniform mat2 u_mat2;

void main() {
    vec2 uv = vec2(0.5, 0.5);
    vec2 transformed = u_mat2 * uv;
    float r = u_float * transformed.x;
    float g = float(u_int) * 0.1 * transformed.y;
    fragColor = vec4(r, g, u_vec3.z, 1.0);
}
