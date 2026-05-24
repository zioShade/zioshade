// Tests: integer bitwise with shifts
#version 450
uniform int u_flags;

void main() {
    int shifted = u_flags << 3;
    int masked = shifted & 0xFF;
    int ored = masked | 0x10;
    int xored = ored ^ 0x55;
    float r = float(xored & 0xFF) / 255.0;
    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);
}
