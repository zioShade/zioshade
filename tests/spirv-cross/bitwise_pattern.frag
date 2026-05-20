#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Bitwise AND/XOR integer pattern
    int x = int(uv.x * 10.0);
    int y = int(uv.y * 10.0);
    int and_val = x & y;
    int xor_val = x ^ y;
    int or_val = x | y;
    float r = float(and_val % 16) / 15.0;
    float g = float(xor_val % 16) / 15.0;
    float b = float(or_val % 16) / 15.0;
    fragColor = vec4(r, g, b, 1.0);
}
