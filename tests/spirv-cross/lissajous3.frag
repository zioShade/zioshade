#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Lissajous with varying parameters
    float a_freq = 5.0;
    float b_freq = 4.0;
    float delta = 0.785;
    float min_d = 1.0;
    for (int i = 0; i <= 40; i++) {
        float t = float(i) / 40.0 * 6.28;
        float x = sin(a_freq * t + delta) * 0.6;
        float y = cos(b_freq * t) * 0.6;
        float d = length(uv - vec2(x, y));
        min_d = min(min_d, d);
    }
    float curve = smoothstep(0.01, 0.005, min_d);
    float glow = smoothstep(0.03, 0.01, min_d) * 0.2;
    vec3 col = vec3(0.02) + vec3(0.4, 0.8, 0.6) * (curve + glow);
    fragColor = vec4(col, 1.0);
}
