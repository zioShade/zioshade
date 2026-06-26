// Tests: multi-component swizzle WRITE whose base is an addressable lvalue that
// is not a bare identifier (#170) — array element (`a[i].yz = ...`), struct
// member (`s.v.xy = ...`), and a dynamic array index. glslpp's plain swizzle-write
// path only handled bare-identifier bases; anything else fell through to a generic
// lvalue assignment that cannot address a multi-component swizzle
// (error.InvalidAssignment), wrongly rejecting valid GLSL. The base vector is now
// reached via analyzeLValue and the new values shuffled in. The path is gated to a
// real swizzle name (xyzw/rgba), so a member name on a simplified-vec4 builtin
// (e.g. gl_Position) is NOT mis-read as a swizzle.
#version 450
layout(location = 0) in vec2 t;
layout(location = 1) flat in int i;
layout(location = 0) out vec4 o;

struct S { vec3 v; };

void main() {
    vec3 a[3];
    a[0] = vec3(t, 1.0);
    a[1] = vec3(0.0);
    a[2] = vec3(2.0);
    a[0].yz = t;            // static array-element swizzle write
    a[i].xy = t.yx;         // dynamic array-element swizzle write

    S s;
    s.v = vec3(3.0);
    s.v.xz = t;             // struct-member swizzle write

    o = vec4(a[0] + a[i], s.v.x);
}
