#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Weierstrass function (continuous everywhere, differentiable nowhere)
    float x = uv.x * 3.0;
    float sum = 0.0;
    float a = 0.5;
    float b = 3.0;
    for (int n = 0; n < 15; n++) {
        float fn = float(n);
        float freq = pow(b, fn);
        float amp = pow(a, fn);
        sum += amp * cos(freq * 3.14159 * x);
    }
    float d = abs(uv.y - sum * 0.3);
    float line = smoothstep(0.01, 0.005, d);
    vec3 col = vec3(0.05) + vec3(0.8, 0.6, 0.2) * line;
    fragColor = vec4(col, 1.0);
}
