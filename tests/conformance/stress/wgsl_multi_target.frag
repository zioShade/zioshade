// Tests: multi-target switch with default
#version 450
uniform int u_mode;

void main() {
    float r;
    switch (u_mode) {
        case 0: r = 0.2; break;
        case 1: r = 0.4; break;
        case 2: r = 0.6; break;
        case 3: r = 0.8; break;
        default: r = 0.0; break;
    }
    gl_FragColor = vec4(r, r, r, 1.0);
}
