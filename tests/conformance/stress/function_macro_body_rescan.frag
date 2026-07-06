// Tests: a function-like macro whose body calls another macro (#170). The C
// preprocessor RESCANS a macro's replacement for further macros, so
// `#define WRAP(z) ADD(SQ(z), 1.0)` expands to `ADD(SQ(t), 1.0)` and that
// `ADD(...)`/`SQ(...)` must then expand too. zioshade emitted the substituted body
// raw, so the body's macro calls reached the parser undefined. Completes the
// rescan started for object-macro bodies (#385) and argument pre-expansion (#384).
#version 450
#define ADD(a, b) ((a) + (b))
#define SQ(x) ((x) * (x))
#define WRAP(z) ADD(SQ(z), 1.0)
#define SCALE(v) ADD(v, v)

layout(location = 0) in float t;
layout(location = 0) out vec4 o;

void main() {
    float a = WRAP(t);          // -> ADD(SQ(t), 1.0)
    float b = SCALE(WRAP(t));   // arg WRAP(t) pre-expanded, body ADD re-expanded
    o = vec4(a, b, a + b, 1.0);
}
