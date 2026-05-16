#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Polar to cartesian conversion
    float r = uv.x * 2.0;
    float theta = uv.y * 6.28318;

    vec2 cartesian = vec2(r * cos(theta), r * sin(theta));

    float col = sin(cartesian.x * 5.0) * cos(cartesian.y * 5.0);
    col = col * 0.5 + 0.5;

    fragColor = vec4(col, col * 0.7, 1.0 - col, 1.0);
}
