#version 450

// Test: nested loop with linear search
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float target = uv.x;
    float found = 0.0;
    int foundIdx = -1;

    for (int i = 0; i < 10; i++) {
        float fi = float(i) / 10.0;
        if (foundIdx < 0 && fi > target) {
            found = fi;
            foundIdx = i;
        }
    }

    float r = foundIdx >= 0 ? found : 1.0;
    gl_FragColor = vec4(r, uv.y, float(max(foundIdx, 0)) / 10.0, 1.0);
}
