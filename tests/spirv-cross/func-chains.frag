#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

float accumulate(float base) {
    float total = base;
    for (int i = 0; i < 5; i++) {
        total += float(i) * 0.1;
    }
    return total;
}

float transform(vec2 p) {
    return sin(p.x * 3.14159) * cos(p.y * 3.14159);
}

void main() {
    float a = accumulate(uv.x);
    float b = transform(uv);
    float c = clamp(a * b, 0.0, 1.0);
    fragColor = vec4(c, a * 0.5, b * 0.5, 1.0);
}
