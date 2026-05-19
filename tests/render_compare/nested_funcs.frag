#version 430
layout(location = 0) out vec4 FragColor;

// Test nested function calls
float add(float a, float b) { return a + b; }
float mul(float a, float b) { return a * b; }
float combo(float x) { return add(mul(x, 2.0), 0.5); }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    float a = combo(uv.x);
    float b = combo(uv.y);
    FragColor = vec4(clamp(a, 0.0, 1.0), clamp(b, 0.0, 1.0), 0.5, 1.0);
}
