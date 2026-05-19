#version 450

// Test CopyObject-like patterns: simple variable assignments and reassignment
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    // Simple copy
    float a = x;
    a = a * 2.0;

    // Copy through function-like pattern
    float b = y;
    float c = b;
    c += 0.5;
    c = clamp(c, 0.0, 1.0);

    // Copy vector
    vec2 v = uv;
    vec2 w = v;
    w.x += 0.1;

    gl_FragColor = vec4(a, c, w.x, 1.0);
}
