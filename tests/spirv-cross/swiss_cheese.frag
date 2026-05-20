#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Swiss cheese pattern with random holes
    vec3 col = vec3(0.95, 0.92, 0.7); // cheese color
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(fi * 2.17 + 0.5) * 0.7,
            cos(fi * 1.73 + 1.2) * 0.7
        );
        float size = 0.05 + 0.1 * fract(sin(fi * 74.3) * 43758.5);
        float d = length(uv - center);
        float hole = smoothstep(size, size * 0.7, d);
        col = mix(col, vec3(0.6, 0.5, 0.3), hole);
    }
    col *= smoothstep(1.1, 0.95, length(uv));
    fragColor = vec4(col, 1.0);
}
