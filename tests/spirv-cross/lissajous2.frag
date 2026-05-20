#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Lissajous figure with trails
    float a = 3.0;
    float b = 4.0;
    float delta = 1.57;
    vec3 col = vec3(0.02);
    for (int i = 0; i <= 50; i++) {
        float t = float(i) / 50.0 * 6.28;
        float x = 5.0 + sin(a * t + delta) * 4.0;
        float y = 5.0 + sin(b * t) * 4.0;
        float d = length(uv - vec2(x, y));
        float bright = float(i) / 50.0;
        col += vec3(0.3, 0.6 + bright * 0.3, 1.0) * smoothstep(0.08, 0.02, d) * bright;
    }
    fragColor = vec4(col, 1.0);
}
