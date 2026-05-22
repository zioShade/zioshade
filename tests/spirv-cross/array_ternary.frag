#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Array initialized with function calls, then switch on index
    float arr[4];
    for (int i = 0; i < 4; i++) {
        arr[i] = abs(sin(uv.x * float(i + 1) * 3.14159));
    }

    int idx = int(uv.y * 3.0);
    idx = clamp(idx, 0, 3);

    // Use the array value in a ternary chain
    float v = idx == 0 ? arr[0] : (idx == 1 ? arr[1] : (idx == 2 ? arr[2] : arr[3]));

    vec3 col = vec3(v);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
