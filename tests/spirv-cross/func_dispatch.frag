#version 450

// Test: double dispatch pattern (multiple functions with same name)
float calc(float x) { return x * x; }
vec2 calc(vec2 v) { return v * v; }
float calc(float a, float b) { return a + b; }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float f = calc(uv.x);
    vec2 v = calc(uv);
    float s = calc(uv.x, uv.y);
    gl_FragColor = vec4(f, v.x, s, 1.0);
}
