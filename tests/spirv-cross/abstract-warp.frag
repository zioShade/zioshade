#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Warp coordinates for abstract pattern
    vec2 p = uv * 6.28318;

    float x = sin(p.x + sin(p.y)) * cos(p.y - cos(p.x));
    float y = cos(p.x * 1.3 + sin(p.y * 0.7)) * sin(p.y * 0.9 + cos(p.x * 1.1));

    vec3 col;
    col.r = sin(x * 3.0) * 0.5 + 0.5;
    col.g = sin(y * 3.0 + 1.0) * 0.5 + 0.5;
    col.b = sin((x + y) * 2.0 + 2.0) * 0.5 + 0.5;

    fragColor = vec4(col, 1.0);
}
