#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Sunflower seed arrangement (Fibonacci)
    float golden = 2.399963;
    vec3 col = vec3(0.05, 0.08, 0.02);
    for (int i = 0; i < 80; i++) {
        float fi = float(i);
        float seed_r = sqrt(fi / 80.0) * 0.9;
        float seed_a = fi * golden;
        vec2 seed_pos = vec2(cos(seed_a), sin(seed_a)) * seed_r;
        float d = length(uv - seed_pos);
        float size = 0.02 + 0.01 * fract(sin(fi * 93.13) * 43758.5);
        float seed = smoothstep(size, size * 0.5, d);
        float bright = 0.6 + 0.4 * fract(sin(fi * 17.3) * 43758.5);
        col = mix(col, vec3(bright * 0.9, bright * 0.75, bright * 0.3), seed);
    }
    fragColor = vec4(col, 1.0);
}
