#version 450

// Test: complex expression with many operators in one statement
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    float a = (x * 2.0 + y) * (x - y * 0.5) + (x + y) * (x - y);
    float b = sin(x * 3.14) * cos(y * 1.57) + tan(x * 0.78);
    float c = pow(x, 2.0) + pow(y, 3.0) - sqrt(x * y + 0.01);
    float d = (a + b + c) / (abs(a) + abs(b) + abs(c) + 0.001);

    gl_FragColor = vec4(clamp(d, 0.0, 1.0), clamp(b * 0.5 + 0.5, 0.0, 1.0), clamp(c * 0.3 + 0.5, 0.0, 1.0), 1.0);
}
