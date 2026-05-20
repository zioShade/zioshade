#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Perlin worm / flow texture
    vec2 p = uv;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        p = p + vec2(
            sin(p.y * 3.0 + fi * 1.7) * 0.5,
            cos(p.x * 3.0 + fi * 2.3) * 0.5
        );
    }
    float pattern = sin(p.x * 4.0) * sin(p.y * 4.0);
    pattern = pattern * 0.5 + 0.5;
    vec3 col = vec3(pattern, pattern * 0.6, pattern * 0.3);
    fragColor = vec4(col, 1.0);
}
