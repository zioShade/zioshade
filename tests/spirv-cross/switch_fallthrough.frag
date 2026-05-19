#version 450

// Test switch statement with default and fallthrough
float pattern(int n) {
    float v = 0.0;
    switch (n) {
        case 0: v = 0.1; break;
        case 1: v = 0.2; break;
        case 2:
        case 3: v = 0.4; break;
        case 4: v = 0.6; break;
        default: v = 0.8; break;
    }
    return v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int n = int(uv.x * 6.0);
    float v = pattern(n);
    gl_FragColor = vec4(v, uv.y, v * uv.y, 1.0);
}
