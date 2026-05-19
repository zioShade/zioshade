#version 450

// Test: mix of all basic types in expression
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    int i = int(uv.x * 5.0);
    uint u = uint(uv.y * 10.0);
    float f = uv.x + uv.y;
    bool b = f > 1.0;

    float result = float(i) / 5.0 + float(u) / 20.0 + f * 0.1;
    result = b ? result * 2.0 : result;

    gl_FragColor = vec4(clamp(result, 0.0, 1.0), float(b) * 0.5, float(u) / 10.0, 1.0);
}
