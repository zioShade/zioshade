// Tests: a constant arithmetic expression as an array size (#170). GLSL allows
// `const int N = 3; float a[N + 1];` and other const arithmetic dimensions. The
// parser stores such a dimension as source text, and the resolver previously only
// folded bare names / literals — `a[N + 1]` failed (SemanticFailed). The resolver
// now re-parses the size text and folds the const expression (evalConstInt over
// +, -, *, /, %, parens, and const-global names).
#version 450
layout(location = 0) flat in int i;
layout(location = 0) out vec4 o;

const int N = 3;
const int K = N - 1;             // = 2

void main() {
    float a[N + 1];              // = 4
    float b[N * 2];              // = 6
    float c[(N + 1) / 2];        // = 2
    float d[K];                  // const-from-const arithmetic = 2

    a[3] = 1.0;
    b[5] = 2.0;
    c[1] = 3.0;
    d[1] = 4.0;

    // dynamic indices keep the arrays materialized
    o = vec4(a[i % (N + 1)] + b[i % (N * 2)], c[i % 2], d[i % K], 1.0);
}
