#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Coral reef texture
    vec3 col = vec3(0.05, 0.15, 0.25);
    // Coral branches
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 base = vec2(fract(sin(fi * 127.1) * 43758.5) * 10.0 + 1.0, fract(sin(fi * 311.7) * 43758.5) * 3.0 + 1.0);
        float angle = fract(sin(fi * 74.3) * 43758.5) * 6.28;
        vec2 dir = vec2(cos(angle), sin(angle));
        float height = 1.0 + fract(sin(fi * 93.1) * 43758.5) * 3.0;
        for (int j = 0; j < 4; j++) {
            float fj = float(j);
            vec2 bp = base + dir * fj * 0.4;
            float d = length(uv - bp);
            float size = 0.2 - fj * 0.03;
            float branch = smoothstep(size, size * 0.5, d);
            vec3 coral = vec3(
                0.8 + fj * 0.05,
                0.3 + fract(sin(fi * fj * 13.7) * 43758.5) * 0.3,
                0.3 + fract(sin(fi * fj * 51.3) * 43758.5) * 0.2
            );
            col = mix(col, coral, branch);
        }
    }
    // Sandy bottom
    col = mix(col, vec3(0.7, 0.6, 0.4), smoothstep(2.0, 1.0, uv.y));
    fragColor = vec4(col, 1.0);
}
