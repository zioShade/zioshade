// Tests: an array-size expression that STARTS with an integer literal (#170).
// `a[2 * N]`, `a[8 / N]` etc. were mis-parsed — the parser's dimension scan took
// the int-literal fast-path on the leading literal, set the size to it, then
// choked on the operator, breaking the declaration (valid GLSL wrongly rejected).
// The fast-path now only fires for a pure `[literal]` (next token is `]`); a
// literal-led expression falls to the const-expression fold.
#version 450
layout(location = 0) flat in int i;
layout(location = 0) out vec4 o;

const int N = 4;

void main() {
    float a[2 * N];          // = 8 (was mis-parsed as 2)
    float b[8 / N];          // = 2
    float c[N + 2];          // name-led control (already worked) = 6

    a[7] = 1.0;
    b[1] = 2.0;
    c[5] = 3.0;

    // dynamic indices keep the arrays materialized
    o = vec4(a[i % (2 * N)], b[i % (8 / N)], c[i % (N + 2)], 1.0);
}
