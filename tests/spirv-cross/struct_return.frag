#version 450

// Test out parameter qualifiers via struct return pattern
// (GLSL 430 doesn't have out params easily testable, use struct return)
struct Pair {
    float a;
    float b;
};

Pair split(float x) {
    Pair p;
    p.a = fract(x);
    p.b = floor(x);
    return p;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Pair p = split(uv.x * 5.0);
    gl_FragColor = vec4(p.a, p.b / 5.0, uv.y, 1.0);
}
