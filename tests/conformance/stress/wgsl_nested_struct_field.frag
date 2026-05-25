// Tests: deeply nested struct field access across functions
#version 450
layout(location = 0) out vec4 fragColor;

struct Inner { float a; float b; };
struct Outer { Inner data; float scale; };

float sumInner(Inner i) {
    return i.a + i.b;
}

float processOuter(Outer o) {
    return sumInner(o.data) * o.scale;
}

void main() {
    Outer o;
    o.data.a = 3.0;
    o.data.b = 4.0;
    o.scale = 0.5;
    float result = processOuter(o);
    fragColor = vec4(vec3(fract(result)), 1.0);
}
