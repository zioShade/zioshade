// Tests: a const-qualified integer global used as an array size (#170). GLSL
// `const int N = 3; float a[N];` is valid and common, but zioshade's array-size
// resolver only handled integer literals and gl_WorkGroupSize — a const-global
// name failed (SemanticFailed), wrongly rejecting valid GLSL. evalConstInt now
// folds a const-global identifier, and resolveSizeExpr resolves the name.
#version 450
layout(location = 0) flat in int i;
layout(location = 0) out vec4 o;

const int N = 3;
const int M = N;                 // const-from-const (folds transitively)
const vec2 dirs[N] = vec2[](vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(-1.0, 0.0)); // global const-N array

void main() {
    float a[N];                  // local array sized by a const global
    a[0] = 1.0;
    a[1] = 2.0;
    a[2] = 3.0;

    float b[M];                  // sized by a const-from-const
    b[0] = a[i % N];
    b[1] = 5.0;
    b[2] = 6.0;

    // dynamic indices keep the arrays materialized
    o = vec4(a[i % N], b[i % M], dirs[i % N]);
}
