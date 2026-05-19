#version 450

// Test: nested function calls with struct return
struct Result {
    float value;
    vec3 color;
};

Result compute(float x) {
    Result r;
    r.value = sin(x) * 0.5 + 0.5;
    r.color = vec3(r.value, 1.0 - r.value, x);
    return r;
}

Result combine(Result a, Result b) {
    Result r;
    r.value = (a.value + b.value) * 0.5;
    r.color = mix(a.color, b.color, 0.5);
    return r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Result r1 = compute(uv.x);
    Result r2 = compute(uv.y);
    Result r3 = combine(r1, r2);
    gl_FragColor = vec4(r3.color, 1.0);
}
