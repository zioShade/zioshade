// Tests: clamp and saturate
#version 450
uniform float u_val;

void main() {
    float c = clamp(u_val, 0.0, 1.0);
    float r = c * c;
    gl_FragColor = vec4(r, c, 1.0 - c, 1.0);
}
