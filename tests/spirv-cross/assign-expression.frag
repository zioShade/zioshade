#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test assignment-as-expression: (a = x) returns x
    float a;
    float b = (a = uv.x) + 0.5;

    // Test chained assignment
    float c;
    c = a = uv.y;

    fragColor = vec4(a, b, c, 1.0);
}
