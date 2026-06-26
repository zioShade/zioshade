// Tests: object-like macro chains (#170). The C preprocessor RESCANS a macro's
// replacement for further macros, so `#define A B` / `#define B 5` expands `A`
// all the way to `5`, and `#define SQT SQ(2.0)` expands the inner function macro.
// glslpp emitted object-macro bodies raw (no rescan), so `A` reached the parser
// as undefined `B`. Also, `#define H (W/2)` — a SPACE before the `(` — is an OBJECT
// macro whose body is `(W/2)`, not function-like; the define parser misclassified
// the spaced form as function-like (keying on the `(` token without checking
// adjacency), so a bare `H` was never expanded. Both forms are very common.
#version 450
#define A B
#define B 5.0
#define SQ(x) ((x) * (x))
#define SQT SQ(2.0)
#define W 800
#define H (W / 2)
#define AREA (W * H)

layout(location = 0) out vec4 o;

void main() {
    float x = A;            // A -> B -> 5.0
    float y = SQT;          // SQT -> SQ(2.0) -> ((2.0)*(2.0))
    float z = float(AREA);  // AREA -> (W*H) -> (800*(800/2))
    o = vec4(x, y, z, 1.0);
}
