#version 450

// Test integer division, modulo, bitwise ops on uints
void main() {
    uint a = 17u;
    uint b = 5u;
    uint c = a / b;      // UDiv
    uint d = a % b;      // UMod
    uint e = a << 2u;    // ShiftLeft
    uint f = a >> 1u;    // ShiftRightLogical
    uint g = a & 0xFFu;  // BitwiseAnd
    uint h = a | 0x10u;  // BitwiseOr
    uint i = a ^ 0xAAu;  // BitwiseXor
    uint j = ~a;         // Not

    int sa = -17;
    int sb = 5;
    int sc = sa / sb;    // SDiv
    int sd = sa % sb;    // SRem or SMod
    int se = sa >> 2;    // ShiftRightArithmetic
    int sf = ~sa;        // Not

    float r = float(c) / 4.0;
    float gr = float(d) / 4.0;
    float bl = float(g & 0xFu) / 16.0;
    gl_FragColor = vec4(r, gr, bl, 1.0);
}
