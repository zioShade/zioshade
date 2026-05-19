#version 450

// Test: nested function calling patterns
float add(float a, float b) { return a + b; }
float mul(float a, float b) { return a * b; }

float poly(float x) {
    // 3x^2 + 2x + 1
    return add(mul(3.0, mul(x, x)), add(mul(2.0, x), 1.0));
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 2.0 - 1.0;
    float y = poly(x);
    gl_FragColor = vec4(clamp(y * 0.2, 0.0, 1.0), uv.y, x * 0.5 + 0.5, 1.0);
}
