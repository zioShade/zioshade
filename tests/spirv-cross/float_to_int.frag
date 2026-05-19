#version 450

// Test: float to int conversion edge cases
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float f1 = -0.5;
    float f2 = 0.5;
    float f3 = 2.7;
    float f4 = -2.7;

    int i1 = int(f1);   // 0
    int i2 = int(f2);   // 0
    int i3 = int(f3);   // 2
    int i4 = int(f4);   // -2

    uint u1 = uint(uv.x * 10.0);

    float r = float(i1 + i2 + 2) / 4.0;
    float g = float(i3) / 5.0;
    float b = float(i4 + 3) / 6.0;

    gl_FragColor = vec4(r, g, b, 1.0);
}
