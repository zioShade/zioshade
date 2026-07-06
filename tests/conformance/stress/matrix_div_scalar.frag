// Tests: binary `mat / scalar` (#170). GLSL divides every component by the
// scalar, but SPIR-V has no whole-matrix OpFDiv — zioshade emitted OpFDiv on the
// matrix operand (invalid SPIR-V: "Expected floating scalar or vector type").
// The lowering must be `mat * (1.0/scalar)` via OpMatrixTimesScalar, matching
// glslang. Covers float and int scalars across mat2/mat3.
#version 450
layout(location = 0) in float tf;
layout(location = 1) flat in int ti;
layout(location = 0) out vec4 o;

void main() {
    mat2 a = mat2(4.0);
    mat2 d2f = a / tf;      // reciprocal * OpMatrixTimesScalar
    mat2 d2i = a / ti;      // int -> float reciprocal, then OpMatrixTimesScalar
    mat3 b = mat3(9.0);
    mat3 d3 = b / 3.0;      // constant scalar

    o = vec4(d2f[0], d2i[0]) + vec4(d3[0], 1.0);
}
