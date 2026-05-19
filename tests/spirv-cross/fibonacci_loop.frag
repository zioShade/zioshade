#version 450

// Test: fibonacci computation via loop (not recursion)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int n = int(uv.x * 10.0) + 1;

    int a = 0;
    int b = 1;
    for (int i = 0; i < n && i < 15; i++) {
        int temp = a + b;
        a = b;
        b = temp;
    }

    float r = float(a) / 100.0;
    float g = float(b) / 200.0;
    float bl = float(n) / 15.0;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), bl, 1.0);
}
