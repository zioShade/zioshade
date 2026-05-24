// Tests: switch statement with default
#version 450
uniform int u_mode;
uniform float u_val;

void main() {
    float result;
    switch (u_mode) {
        case 0: result = u_val * 2.0; break;
        case 1: result = u_val + 1.0; break;
        case 2: result = sqrt(u_val); break;
        default: result = 0.0; break;
    }
    gl_FragColor = vec4(result, 0.0, 0.0, 1.0);
}
