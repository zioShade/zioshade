#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // Integer and bitwise operations
    ivec2 uv = ivec2(gl_FragCoord.xy);
    int x = uv.x;
    int y = uv.y;
    // Bitwise AND pattern
    int val = x & y;
    float f = float(val & 0xFF) / 255.0;
    // XOR pattern overlay
    int xor_val = x ^ y;
    float xor_f = float(xor_val & 0xFF) / 255.0;
    vec3 col = vec3(f, xor_f, f * xor_f);
    fragColor = vec4(col, 1.0);
}
