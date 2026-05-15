#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test compound assignment operators
    float a = uv.x;
    a += 0.5;
    a *= 2.0;
    a -= 1.0;
    a /= 3.0;

    vec2 b = uv;
    b += vec2(0.1, 0.2);
    b *= 0.5;
    b -= vec2(0.05);
    b /= 2.0;

    int c = int(uv.x * 10.0);
    c += 5;
    c *= 2;
    c -= 3;
    c /= 4;

    fragColor = vec4(a, b, float(c) / 20.0);
}
