// Tests: synthetic preprocessor tokens reaching the parser (#170). The `##` token
// paste, `__LINE__`, and `__VERSION__` produce token text that does not exist
// contiguously in the original source; the producers store it in the preprocessor's
// synthetic-text buffer (offset >= source.len) and the parser reads an EXTENDED
// source (original + synthetic buffer) so those offsets resolve. Previously the
// parser read the original source by offset, so a pasted/__LINE__ token read the
// first bytes of the source ("#v…" from "#version") — UndeclaredIdentifier /
// non-numeric int_literal, wrongly rejecting valid GLSL.
#version 450
#define CAT(a, b) a ## b
#define MAKE(n) col ## n

layout(location = 0) out vec4 o;

void main() {
    float pos = 3.0;
    float colA = 1.0;
    float r = CAT(p, os);     // -> pos
    float g = MAKE(A);        // -> colA
    int ln = __LINE__;        // current line number
    int ver = __VERSION__;    // 450
    o = vec4(r, g, float(ln) * 0.01, float(ver) * 0.001);
}
