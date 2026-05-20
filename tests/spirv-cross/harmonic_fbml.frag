#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Fractal Brownian Motion with domain warping
    float t = uv.x;
    float f = 0.0;
    float amp = 1.0;
    float freq = 1.0;
    for (int i = 0; i < 5; i++) {
        f += amp * sin(t * freq * 6.28 + float(i) * 1.7);
        freq *= 2.0;
        amp *= 0.5;
    }
    f = f * 0.5 + 0.5;
    vec3 col = mix(vec3(0.1, 0.2, 0.3), vec3(0.9, 0.8, 0.6), f);
    fragColor = vec4(col, 1.0);
}
