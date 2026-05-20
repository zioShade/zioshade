#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Integer operations for pattern generation
    int x = int(floor(uv.x * 10.0)) + 5;
    int y = int(floor(uv.y * 10.0)) + 5;
    // GCD-based pattern
    int a = x;
    int b = y;
    for (int i = 0; i < 8; i++) {
        int temp = b;
        b = a - (a / b) * b;
        a = temp;
        if (b == 0) break;
    }
    float pattern = float(a) / 10.0;
    vec3 col = vec3(pattern, pattern * 0.7, pattern * 0.4);
    fragColor = vec4(col, 1.0);
}
