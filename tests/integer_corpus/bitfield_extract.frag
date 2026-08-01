#version 450
// Exercises OpBitFieldSExtract / OpBitFieldUExtract (GLSL bitfieldExtract).
// UB-free: offset = y&0x1C (0..28 step 4), count = 4 -> offset+count <= 32.
layout(location = 0) out vec4 FragColor;
void main() {
    int x = int(gl_FragCoord.x);
    int off = int(gl_FragCoord.y) & 0x1C;
    int se = bitfieldExtract(x, off, 4);          // signed extract
    uint ue = bitfieldExtract(uint(x), off, 4);   // unsigned extract
    FragColor = vec4(float(se), float(ue), float(off), 1.0);
}
