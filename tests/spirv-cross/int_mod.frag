#version 450

// Test: imod/smod and negative remainders
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int a = int(uv.x * 10.0) - 5;
    int b = int(uv.y * 10.0) - 5;

    int c = a % 3;
    int d = b % 3;
    int e = (a + 5) * (b + 5);

    float r = float(c + 3) / 6.0;
    float g = float(d + 3) / 6.0;
    float bl = float(e) / 100.0;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(bl, 0.0, 1.0), 1.0);
}
