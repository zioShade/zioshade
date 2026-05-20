#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Butterfly curve (Temple H. Fay)
    float min_d = 1.0;
    for (int i = 0; i <= 80; i++) {
        float t = float(i) / 80.0 * 6.28 * 6.0;
        float r = exp(sin(t)) - 2.0 * cos(4.0*t) + pow(sin((2.0*t - 3.14159)/8.0), 5.0);
        float x = r * sin(t) * 0.3 + 5.0;
        float y = r * cos(t) * 0.3 + 5.0;
        float d = length(uv - vec2(x, y));
        min_d = min(min_d, d);
    }
    float curve = smoothstep(0.02, 0.01, min_d);
    vec3 col = vec3(0.02) + vec3(0.9, 0.5, 0.2) * curve;
    fragColor = vec4(col, 1.0);
}
