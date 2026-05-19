#version 450

// Test OpSelect patterns via ternary with mixed types
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    bool cond = uv.x > 0.5;
    float a = cond ? 1.0 : 0.0;
    vec2 b = cond ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    vec4 c = cond ? vec4(uv, 0.0, 1.0) : vec4(0.0, 0.0, uv);

    bool c2 = uv.y > 0.3;
    int d = c2 ? 3 : 7;
    float e = float(d) / 10.0;

    gl_FragColor = vec4(a, b, e);
}
