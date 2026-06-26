// Tests: component-wise matrix arithmetic with a scalar (#170). GLSL `mat + s`,
// `s - mat`, `s / mat` (and `mat / mat`) apply the op to every component, but
// SPIR-V has no matrix OpFAdd/OpFSub/OpFDiv with a scalar (or whole-matrix divide).
// glslpp emitted those on a (matrix, scalar) / (matrix, matrix) pair = invalid
// SPIR-V. The scalar is splatted into a matrix and the op decomposes per column;
// matrix OpFDiv is now decomposed per-column in codegen too (so `mat / mat` and
// the splat-based `s / mat` both work).
//
// Divisor matrices are built from the runtime input (full, non-zero) so the
// component-wise division never folds to a 0/0 NaN literal.
#version 450
layout(location = 0) in float tf;
layout(location = 1) flat in int ti;
layout(location = 0) out vec4 o;

void main() {
    mat2 m = mat2(2.0);                                  // diagonal — fine for + and -
    mat2 dm = mat2(tf + 1.0, tf + 2.0, tf + 3.0, tf + 4.0); // full, runtime divisor

    mat2 a = m + tf;     // splat + column-wise OpFAdd
    mat2 b = tf - m;     // splat (scalar on left) + column-wise OpFSub
    mat2 c = m + ti;     // int -> float, splat, OpFAdd
    mat2 d = tf / dm;    // splat + column-wise OpFDiv (no 0/0)
    mat3 e = mat3(3.0);
    mat3 f = e - 1.0;    // mat3 + constant scalar

    mat2 g = mat2(tf + 5.0, tf + 6.0, tf + 7.0, tf + 8.0);
    mat2 h = g / dm;     // matrix / matrix, column-wise OpFDiv

    o = vec4(a[0], b[0]) + vec4(c[0], d[0]) + vec4(f[0].xy, h[0]);
}
