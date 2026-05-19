#version 450

// Test: multiple functions calling each other (mutual dependency)
float helperA(float x);
float helperB(float x);

float helperA(float x) {
    if (x < 0.1) return x;
    return helperB(x * 0.5);
}

float helperB(float x) {
    if (x < 0.1) return x + 0.1;
    return helperA(x - 0.1);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = helperA(uv.x);
    float b = helperB(uv.y);
    gl_FragColor = vec4(a, b, (a + b) * 0.5, 1.0);
}
