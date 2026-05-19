#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int n = int(uv.x * 15.0) + 1;
    int a = 0;
    int b = 1;
    for (int i = 2; i < 16; i++) {
        if (i > n) break;
        int c = a + b;
        a = b;
        b = c;
    }
    float val = float(b % 10) / 10.0;
    val *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(val, val * 0.7, val * 0.3, 1.0);
}
