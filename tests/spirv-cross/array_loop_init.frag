#version 450

// Test: array with loop initialization
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float vals[5];
    for (int i = 0; i < 5; i++) {
        vals[i] = float(i) / 5.0 + uv.x * 0.2;
    }
    int idx = int(uv.y * 4.999);
    idx = clamp(idx, 0, 4);
    float v = vals[idx];
    gl_FragColor = vec4(v, float(idx) / 4.0, uv.x, 1.0);
}
