// Tests: conditional store to output
#version 450
uniform float u_val;

void main() {
    vec4 col = vec4(0.0);
    if (u_val > 0.5) {
        col = vec4(1.0, 0.0, 0.0, 1.0);
    } else {
        col = vec4(0.0, 0.0, 1.0, 1.0);
    }
    gl_FragColor = col;
}
