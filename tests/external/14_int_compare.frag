#version 450
// Regression guard: integer <= / >= (signed + unsigned) must lower to WGSL
// comparison operators, not leak their SPIR-V opcode name (SLessThanEqual, ...)
// as a bare identifier. The comparison results are each used more than once so
// they are emitted as statements (exercising getBinOpSymbol), not inlined.
layout(location = 0) flat in ivec4 iv;
layout(location = 0) out vec4 o;

void main() {
    bool sle = iv.x <= iv.y;
    bool sge = iv.x >= iv.y;
    bool ule = uint(iv.z) <= uint(iv.w);
    bool uge = uint(iv.z) >= uint(iv.w);
    // Use each result twice → not single-use → not inlined → statement path.
    float s = float(sle) + float(sge) + float(ule) + float(uge);
    o = vec4(s + float(sle), float(sge), float(ule), float(uge));
}
