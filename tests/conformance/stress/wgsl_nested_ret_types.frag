// Tests: nested function returns with different types
#version 450
layout(location = 0) out vec4 fragColor;

float fnA(float x) { return x * 2.0; }
vec2 fnB(float x) { return vec2(fnA(x), fnA(x + 1.0)); }
vec3 fnC(float x) { vec2 ab = fnB(x); return vec3(ab, fnA(ab.x)); }

void main() {
    vec3 r = fnC(0.5);
    fragColor = vec4(fract(r), 1.0);
}
