#version 450

// Test: integer loop bounds and float conversion
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float sum = 0.0;
    int count = int(uv.x * 8.0) + 1;

    for (int i = 0; i < count && i < 10; i++) {
        sum += 1.0 / float(i + 1);
    }

    float r = sum / 3.0;
    gl_FragColor = vec4(r, uv.y, float(count) / 10.0, 1.0);
}
