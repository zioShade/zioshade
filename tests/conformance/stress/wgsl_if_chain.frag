// Tests: nested if-else chains
#version 450
uniform float u_val;

void main() {
    float result;
    if (u_val < 0.25) {
        result = 0.0;
    } else if (u_val < 0.5) {
        result = 0.33;
    } else if (u_val < 0.75) {
        result = 0.66;
    } else {
        result = 1.0;
    }
    gl_FragColor = vec4(result, u_val, 0.0, 1.0);
}
