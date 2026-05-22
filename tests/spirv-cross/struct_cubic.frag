#version 310 es
precision highp float;
out vec4 fragColor;

// Function with multiple out params via struct
struct Result {
    float value;
    float derivative;
};

Result cubic(float x, float a, float b, float c) {
    Result r;
    r.value = x * x * x * a + x * x * b + x * c;
    r.derivative = 3.0 * x * x * a + 2.0 * x * b + c;
    return r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Result r1 = cubic(uv.x, 1.0, -2.0, 1.0);
    Result r2 = cubic(uv.y, 0.5, 1.0, -0.5);

    float val = r1.value * 0.5 + r2.derivative * 0.3;
    vec3 col = vec3(fract(val), abs(r1.derivative) * 0.2, r2.value * 0.4);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
