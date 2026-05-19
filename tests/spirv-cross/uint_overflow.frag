#version 450

// Test: uint arithmetic overflow behavior
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    uint a = uint(uv.x * 100.0);
    uint b = uint(uv.y * 50.0);

    uint sum = a + b;
    uint diff = a - b;
    uint prod = a * b;
    uint quot = a / max(b, 1u);

    float r = float(sum % 256u) / 256.0;
    float g = float(quot) / 100.0;
    float bl = float(prod % 128u) / 128.0;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(bl, 0.0, 1.0), 1.0);
}
