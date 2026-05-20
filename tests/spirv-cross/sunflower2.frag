#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sunflower seed pattern (Fibonacci angles)
    float golden_angle = 2.39996;
    vec3 col = vec3(0.1, 0.15, 0.05);
    for (int i = 0; i < 60; i++) {
        float fi = float(i);
        float r = sqrt(fi / 60.0) * 0.85;
        float a = fi * golden_angle;
        vec2 pos = vec2(cos(a), sin(a)) * r;
        float d = length(uv - pos);
        float size = 0.02 + 0.008 * fract(sin(fi * 93.1) * 43758.5);
        float seed = smoothstep(size, size * 0.5, d);
        float bright = 0.6 + 0.4 * fract(sin(fi * 17.3) * 43758.5);
        vec3 seed_col = vec3(0.6, 0.5, 0.15) * bright;
        col = mix(col, seed_col, seed);
    }
    fragColor = vec4(col, 1.0);
}
