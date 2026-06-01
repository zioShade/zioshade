#version 450
// Regression guard: WGSL has no isNan builtin. Scalar isnan(x) must lower to the
// standard idiom (x != x), not emit isnan(x) (which naga rejects as undefined).
layout(location = 0) in float a;
layout(location = 0) out vec4 o;

void main() {
    float n = isnan(a) ? 1.0 : 0.0;
    o = vec4(n, 0.0, 0.0, 1.0);
}
