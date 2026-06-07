#version 450
// #173 review: body-surviving mat3x4 const-array fold. Every column is summed
// so nothing folds away, exercising the const-array fold itself (companion to
// mat3x4_const_array_fold_dce.frag which exercises the DCE/identity-fold path).
layout(location=0) out vec4 o;
layout(location=0) flat in int idx;
const mat3x4 M[2] = mat3x4[2](
    mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.),
    mat3x4(1.,2.,3.,4.,5.,6.,7.,8.,9.,10.,11.,12.)
);
void main() {
    mat3x4 m = M[idx];
    o = m[0] + m[1] + m[2];
}
