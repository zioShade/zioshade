#version 450

// Test: conditional nested inside loop body
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float result = 0.0;

    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float x = uv.x * (fi + 1.0);
        float y = uv.y * (fi + 1.0);

        if (x > y) {
            result += sin(x) * 0.1;
        } else {
            result += cos(y) * 0.1;
        }

        if (i > 1) {
            result *= 0.9;
        }
    }

    gl_FragColor = vec4(clamp(result, 0.0, 1.0), uv.y, 0.5, 1.0);
}
