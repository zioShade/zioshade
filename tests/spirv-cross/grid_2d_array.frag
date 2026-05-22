#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // 2D array simulation via float array with index math
    float grid[9];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            int idx = j * 3 + i;
            grid[idx] = sin(uv.x * float(i + 1)) * cos(uv.y * float(j + 1));
        }
    }

    // Dynamic access with computed index
    int r = int(uv.y * 2.0);
    int c = int(uv.x * 2.0);
    r = clamp(r, 0, 2);
    c = clamp(c, 0, 2);
    float val = grid[r * 3 + c];

    // Neighbor access
    float sum = val;
    if (r > 0) sum += grid[(r - 1) * 3 + c];
    if (r < 2) sum += grid[(r + 1) * 3 + c];
    if (c > 0) sum += grid[r * 3 + c - 1];
    if (c < 2) sum += grid[r * 3 + c + 1];

    fragColor = vec4(clamp(vec3(sum * 0.2), 0.0, 1.0), 1.0);
}
