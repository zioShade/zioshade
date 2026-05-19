#version 450

// Test: vec4 swizzle in arithmetic expressions
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 a = vec4(uv, 1.0 - uv);
    vec4 b = vec4(1.0, 0.5, 0.3, 0.7);

    vec4 c = a + b;
    vec4 d = a * b;
    vec4 e = c - d;

    gl_FragColor = vec4(e.xy, e.zw);
}
