#version 450

// Test: nested function returns with different types
float halve(float x) { return x * 0.5; }
vec2 halve(vec2 v) { return v * 0.5; }

float process(float x) {
    return halve(x + 0.1);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = process(uv.x);
    vec2 b = halve(uv);
    float c = process(b.x + b.y);
    gl_FragColor = vec4(a, b, c);
}
