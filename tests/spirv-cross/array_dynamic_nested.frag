#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Local array with dynamic indexing in nested if/else
    float arr[8];
    for (int i = 0; i < 8; i++) {
        arr[i] = float(i) * 0.1 + sin(uv.x * float(i));
    }

    int idx = int(uv.x * 7.0);
    idx = clamp(idx, 0, 7);

    float val = arr[idx];
    if (uv.y > 0.5) {
        val += arr[(idx + 1) % 8];
    } else {
        val += arr[(idx + 3) % 8];
    }

    fragColor = vec4(clamp(vec3(val), 0.0, 1.0), 1.0);
}
