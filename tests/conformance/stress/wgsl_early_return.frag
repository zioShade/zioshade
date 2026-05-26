// Test: nested loops with early return
#version 450

layout(location = 0) out vec4 fragColor;

float searchGrid(vec2 uv, float threshold) {
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            vec2 cell = vec2(float(x), float(y)) / 8.0;
            float d = length(uv - cell);
            if (d < threshold) {
                return 1.0 - d / threshold;
            }
        }
    }
    return 0.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float result = searchGrid(uv, 0.1);
    fragColor = vec4(vec3(result), 1.0);
}
