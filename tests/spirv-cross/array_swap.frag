#version 450

// Test: conditional assignment to array elements
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float arr[3];
    arr[0] = 0.2;
    arr[1] = 0.5;
    arr[2] = 0.8;

    // Conditional swap
    if (uv.x > 0.5) {
        float temp = arr[0];
        arr[0] = arr[2];
        arr[2] = temp;
    }

    int idx = int(uv.y * 2.99);
    float val = arr[idx];

    gl_FragColor = vec4(val, uv.x, uv.y, 1.0);
}
