#version 310 es
precision highp float;
out vec4 fragColor;

// Test: function calling itself recursively (simulated via loop since GLSL doesn't allow recursion)
// Instead: function with accumulator pattern
float accumulate(float x, int n) {
    float sum = 0.0;
    float term = x;
    for (int i = 0; i < n; i++) {
        sum += term;
        term *= -x * x / (float(i + 1) * float(i + 2));
    }
    return sum;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float val = accumulate(uv.x * 2.0, 8);
    vec3 col = vec3(val * 0.3 + 0.5, val * 0.2 + 0.3, val * 0.1 + 0.2);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
