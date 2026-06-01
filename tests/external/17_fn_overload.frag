#version 450
// Regression guard: GLSL function overloading (same name, different parameter
// types) must produce UNIQUE WGSL function names — WGSL has no overloading, so
// emitting two `fn accum(...)` makes naga reject ("redefinition of accum").
// Each call site resolves to its specific overload by SPIR-V function id.
// The loop bodies discourage inlining so the overloads stay as real functions.
layout(location = 0) in vec4 a;
layout(location = 0) out vec4 o;

float accum(float x) { float s = 0.0; for (int i = 0; i < 4; i++) s += x * float(i); return s; }
vec4 accum(vec4 v) { vec4 s = vec4(0.0); for (int i = 0; i < 4; i++) s += v * float(i); return s; }

void main() {
    vec4 vv = accum(a);        // vec4 overload
    float ss = accum(a.x);     // float overload
    o = vv + vec4(ss, ss, ss, ss);
}
