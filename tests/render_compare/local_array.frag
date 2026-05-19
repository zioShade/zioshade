#version 430
layout(location = 0) out vec4 FragColor;

// Test local arrays
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    float arr[4];
    arr[0] = 0.1;
    arr[1] = 0.3;
    arr[2] = 0.5;
    arr[3] = 0.7;
    int idx = int(uv.x * 3.999);
    idx = clamp(idx, 0, 3);
    float val = 0.0;
    for (int i = 0; i < 4; i++) {
        if (i == idx) val = arr[i];
    }
    FragColor = vec4(val, uv.y, val * uv.y, 1.0);
}
