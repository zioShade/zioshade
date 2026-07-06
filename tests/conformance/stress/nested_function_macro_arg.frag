// Tests: a function-like macro call used as an argument to another function-like
// macro (#170). The C preprocessor expands a macro's arguments BEFORE substituting
// them, so `ADD(SQ(t), SQ(t + 1.0))` must expand the inner `SQ(...)` calls first.
// zioshade substituted argument tokens raw, leaving the nested `SQ(...)` unexpanded —
// it reached the parser as a call to an undefined `SQ` (UndeclaredIdentifier),
// wrongly rejecting valid GLSL. A single (non-nested) function macro already worked.
#version 450
#define SQ(x) ((x) * (x))
#define ADD(a, b) ((a) + (b))
#define SCALE(v, s) ((v) * (s))

layout(location = 0) in float t;
layout(location = 0) out vec4 o;

void main() {
    // macro call as each argument
    float a = ADD(SQ(t), SQ(t + 1.0));
    // macro call nested two deep as an argument
    float b = SCALE(ADD(SQ(t), t), 2.0);
    o = vec4(a, b, a + b, 1.0);
}
