#version 310 es
precision highp float;
out vec4 fragColor;

// Array modification in nested loops with conditional swap
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float arr[8];
    for (int i = 0; i < 8; i++) {
        arr[i] = fract(float(i) * 0.137 + uv.x);
    }

    // Bubble sort (partial - 4 passes)
    for (int pass = 0; pass < 4; pass++) {
        for (int j = 0; j < 7; j++) {
            if (arr[j] > arr[j + 1]) {
                float tmp = arr[j];
                arr[j] = arr[j + 1];
                arr[j + 1] = tmp;
            }
        }
    }

    int idx = int(uv.y * 7.0);
    idx = clamp(idx, 0, 7);
    float val = arr[idx];

    vec3 col = vec3(val, arr[0], arr[7]);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
