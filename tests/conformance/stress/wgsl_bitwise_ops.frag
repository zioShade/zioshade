// Tests: integer bitwise and shift operations
#version 450
uniform int u_flags;
uniform int u_mask;

void main() {
    int flags = u_flags;
    int masked = flags & u_mask;
    int shifted = flags << 2;
    int result = masked | shifted;
    float r = float(result & 0xFF) / 255.0;
    gl_FragColor = vec4(r, 0.0, 0.0, 1.0);
}
