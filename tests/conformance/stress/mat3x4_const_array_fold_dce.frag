#version 450
// #173 review (MAJOR regression): mat3x4 const-array fold must stay
// spirv-val-valid even when the body folds away. `acc += m[0]` with
// acc == vec4(0) hits the algebraicSimpl `0.0 + x -> x` identity; the bug
// deleted the live OpStore (its word[pos+2] is the OBJECT operand, mistaken
// for a result id), orphaning the matrix/vector type chain into a dangling
// OpTypeVector %float. Pre-fix: spirv-val "requires a previous definition".
layout(location=0) out vec4 o;
layout(location=0) flat in int idx;
const mat3x4 M[2] = mat3x4[2](
    mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.),
    mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.)
);
void main() {
    mat3x4 m = M[idx];
    vec4 acc = vec4(0.0);
    acc += m[0];
    o = acc;
}
