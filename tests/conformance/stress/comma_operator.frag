// Tests: the GLSL comma operator `(a, b)` (#170). It evaluates its operands
// left-to-right and yields the last operand's value. The semantic layer already
// handled `comma_op`, but the parser only parsed it in for-loop clauses — a
// parenthesized comma expression elsewhere parsed only the first operand, so the
// `)` was never reached and the whole statement/declaration broke, wrongly
// rejecting valid GLSL. Now a full comma expression parses inside parentheses.
#version 450
layout(location = 0) in float t;
layout(location = 1) flat in int n;
layout(location = 0) out vec4 o;

void main() {
    float a = 1.0;
    float b = (a = t, a + 1.0);          // side effect then yield: b = t + 1.0
    float c = (a += 2.0, a * 3.0, a - 1.0); // chained: c = (t + 2.0) - 1.0

    // comma operator as a single function/constructor argument (must NOT be
    // confused with the argument-list comma)
    vec2 v = vec2((float(n), t), 5.0);   // first component = t

    o = vec4(b, c, v);
}
