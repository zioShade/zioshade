#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Barcode pattern
    float x = uv.x;
    float bar_width = 0.3;
    // EAN-13 style encoding: 6 bars + 6 bars
    float code = 0.0;
    // Start guard
    code += step(0.0, x) * step(x, 0.3);
    // Left group (variable-width bars)
    float left_data = fract(sin(floor(x / 0.8) * 127.1) * 43758.5);
    code += step(0.5, left_data) * step(0.5, x) * step(x, 5.0);
    // Center guard
    code += step(5.0, x) * step(x, 5.6);
    // Right group
    float right_data = fract(sin(floor(x / 0.8) * 311.7) * 43758.5);
    code += step(0.5, right_data) * step(5.6, x) * step(x, 10.0);
    // End guard
    code += step(10.0, x) * step(x, 10.6);
    float bar = fract(x / bar_width);
    float stripe = step(0.4, bar) * code;
    vec3 col = vec3(1.0 - stripe);
    fragColor = vec4(col, 1.0);
}
