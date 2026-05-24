// Tests: nested ternary with different types
#version 450
uniform float u_val;

void main() {
    float x = u_val > 0.5 ? (u_val > 0.8 ? 1.0 : 0.5) : 0.0;
    vec3 col = x > 0.25 ? vec3(1.0, 0.5, 0.0) : vec3(0.0, 0.5, 1.0);
    gl_FragColor = vec4(col * x, 1.0);
}
