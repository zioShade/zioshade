#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test struct with array member
    struct S {
        float values[4];
    };

    S s;
    for (int i = 0; i < 4; i++) {
        s.values[i] = uv.x * float(i + 1) * 0.25;
    }

    // Test nested struct
    struct Pair {
        float a;
        float b;
    };

    struct Container {
        Pair p;
        float extra;
    };

    Container c;
    c.p.a = uv.x;
    c.p.b = uv.y;
    c.extra = 0.5;

    // Test struct constructor
    Pair q = Pair(c.p.a + 0.1, c.p.b + 0.1);

    fragColor = vec4(s.values[0] + q.a, s.values[1] + q.b, c.extra, 1.0);
}
