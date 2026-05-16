#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Bar chart visualization
    float bars = 5.0;
    float bar_width = 0.8 / bars;
    float x = fract(uv.x * bars);
    float bar_index = floor(uv.x * bars);

    // Height from hash
    float h = fract(sin(bar_index * 127.1) * 43758.5453);

    float in_bar = step(0.1, x) * step(x, 0.9);
    float below_top = step(uv.y, h);

    float col = in_bar * below_top;

    vec3 bar_color = vec3(
        0.3 + h * 0.5,
        0.5 + sin(h * 3.14) * 0.3,
        0.7 - h * 0.3
    );

    fragColor = vec4(bar_color * col + vec3(0.05), 1.0);
}
