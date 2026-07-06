// Tests: compound `mat += scalar` / `mat -= scalar` (#170). GLSL applies the
// scalar to every component, but SPIR-V has no matrix OpFAdd/OpFSub with a scalar
// operand — zioshade emitted those on a (matrix, scalar) pair = invalid SPIR-V
// ("Expected floating scalar or vector type"). The scalar is splatted into a
// matrix and the op decomposes per column (the compound analog of the binary
// `mat ± scalar` splat). Covers float and int scalars across mat2/mat3.
#version 450
layout(location = 0) in float tf;
layout(location = 1) flat in int ti;
layout(location = 0) out vec4 o;

void main() {
    mat2 a = mat2(2.0);
    a += tf;        // splat + column-wise OpFAdd
    a -= tf;        // splat + column-wise OpFSub
    a += ti;        // int -> float, splat, OpFAdd

    mat3 b = mat3(3.0);
    b -= 1.0;       // constant scalar

    o = vec4(a[0], b[0].xy) + vec4(b[1], 1.0);
}
