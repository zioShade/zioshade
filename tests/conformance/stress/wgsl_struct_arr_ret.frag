// Tests: struct array returned from function
#version 450
layout(location = 0) out vec4 fragColor;

struct Pair { float a; float b; };

Pair makePair(float x) {
    Pair p;
    p.a = x;
    p.b = x * x;
    return p;
}

void main() {
    Pair results[3];
    for (int i = 0; i < 3; i++) {
        results[i] = makePair(float(i) + 0.5);
    }
    float total = 0.0;
    for (int i = 0; i < 3; i++) {
        total += results[i].a + results[i].b;
    }
    fragColor = vec4(vec3(fract(total)), 1.0);
}
