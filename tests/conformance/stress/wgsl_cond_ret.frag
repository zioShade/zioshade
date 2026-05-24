// Tests: conditional returns in WGSL
#version 450
uniform int u_mode;

float getColor(int mode) {
    if (mode == 0) return 1.0;
    if (mode == 1) return 0.5;
    return 0.0;
}

void main() {
    float c = getColor(u_mode);
    gl_FragColor = vec4(c, c, c, 1.0);
}
