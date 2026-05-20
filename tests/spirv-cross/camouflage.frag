#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Camouflage pattern (overlapping blobs)
    vec3 col = vec3(0.4, 0.5, 0.2); // base green
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 center = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 6.0,
            fract(sin(fi * 311.7) * 43758.5) * 6.0
        );
        float size = 0.3 + fract(sin(fi * 93.13) * 43758.5) * 0.5;
        float d = length(uv - center);
        float blob = smoothstep(size + 0.1, size - 0.1, d);
        vec3 blob_col = mix(
            vec3(0.3, 0.4, 0.15),
            vec3(0.5, 0.35, 0.1),
            fract(sin(fi * 74.3) * 43758.5)
        );
        col = mix(col, blob_col, blob);
    }
    fragColor = vec4(col, 1.0);
}
