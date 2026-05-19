#version 450

// Test: complex nested expressions with multiple operators
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    // Chained operations
    float a = ((x + y) * (x - y)) + (x * y * 2.0);
    float b = sin(a * 3.14) + cos(a * 1.57);
    float c = clamp(a * b, -2.0, 2.0) / 2.0 + 0.5;
    float d = mix(x, y, step(0.5, x));

    gl_FragColor = vec4(clamp(c, 0.0, 1.0), clamp(d, 0.0, 1.0), clamp(a * 0.3 + 0.5, 0.0, 1.0), 1.0);
}
