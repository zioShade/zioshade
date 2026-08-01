#version 450
// Exercises OpBitFieldInsert (GLSL bitfieldInsert). UB-free: offset+count <= 32.
layout(location = 0) out vec4 FragColor;
void main() {
    uint base = uint(gl_FragCoord.x);
    uint ins = uint(gl_FragCoord.y);
    int off = int(gl_FragCoord.y) & 0x1C;
    uint r = bitfieldInsert(base, ins, off, 4);
    FragColor = vec4(float(r & 0xFFu), float((r >> 8) & 0xFFu), float((r >> 16) & 0xFFu), 1.0);
}
