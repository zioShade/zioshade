// Tests: matrix `*=` / `/=` by a scalar (#170). GLSL scales every component by
// the scalar, but glslpp's compound-assign path emitted whole-matrix OpFMul/
// OpFDiv (invalid SPIR-V: "Expected floating scalar or vector type"). The lowering
// must use OpMatrixTimesScalar, with `/=` scaling by the reciprocal (matching
// glslang's `mat * (1.0/s)`). Covers float and int scalars across mat2/mat3.
#version 450
layout(location = 0) in float tf;
layout(location = 1) flat in int ti;
layout(location = 0) out vec4 o;

void main() {
    mat2 a = mat2(1.0);
    a *= tf;        // OpMatrixTimesScalar
    a /= tf;        // reciprocal * OpMatrixTimesScalar
    a *= ti;        // int → float, then OpMatrixTimesScalar

    mat3 b = mat3(2.0);
    b /= tf;
    b *= 3.0;       // constant scalar

    o = vec4(a[0], b[0].xy) + vec4(b[1], 1.0);
}
