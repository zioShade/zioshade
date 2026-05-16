#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Integer comparison and conditionals
    int x = int(uv.x * 10.0);
    int y = int(uv.y * 10.0);

    float col = 0.0;
    if (x > y) col += 0.3;
    if (x < y) col += 0.5;
    if (x == y) col += 0.8;
    if (x != 5) col += 0.1;
    if (x >= 3 && x <= 7) col += 0.2;

    fragColor = vec4(col, col * 0.5, col * 0.8, 1.0);
}
