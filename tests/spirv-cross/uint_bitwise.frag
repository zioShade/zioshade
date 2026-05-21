#version 310 es
precision highp float;
out vec4 fragColor;

// Test: unsigned integer bitwise ops
void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    uint x = uint(uv.x * 10.0);
    uint y = uint(uv.y * 10.0);
    uint xor_val = x ^ y;
    uint and_val = x & y;
    uint or_val = x | y;
    uint not_val = ~x;
    float r = float(xor_val % 16u) / 15.0;
    float g = float(and_val % 16u) / 15.0;
    float b = float(or_val % 16u) / 15.0;
    fragColor = vec4(r, g, b, 1.0);
}
