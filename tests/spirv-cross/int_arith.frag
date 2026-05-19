#version 450

// Test: integer arithmetic with signed/unsigned mix
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    int a = int(uv.x * 10.0);
    int b = int(uv.y * 10.0);
    uint c = uint(a + b);
    uint d = uint(a * b + 1);
    int e = int(c - d);

    float r = float(a) / 10.0;
    float g = float(c % 7u) / 7.0;
    float bl = abs(float(e)) / 20.0;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(bl, 0.0, 1.0), 1.0);
}
