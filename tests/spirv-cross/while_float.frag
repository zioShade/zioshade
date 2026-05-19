#version 450

// Test: while loop with float condition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 2.0;

    int iterations = 0;
    while (x > 0.01 && iterations < 20) {
        x = x * x - 0.1;
        iterations++;
    }

    float r = float(iterations) / 20.0;
    float g = x;
    float b = 1.0 - r;

    gl_FragColor = vec4(r, clamp(g, 0.0, 1.0), b, 1.0);
}
