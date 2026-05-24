// Tests: front-facing builtin and discard
#version 450
uniform float u_val;

void main() {
    if (!gl_FrontFacing) discard;
    gl_FragColor = vec4(u_val, 0.0, 1.0, 1.0);
}
