#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Tumor/cell division visualization
    float r = length(uv);
    float col_val = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(fi * 2.1 + 0.5) * 0.4,
            cos(fi * 1.7 + 1.2) * 0.4
        );
        float d = length(uv - center);
        float size = 0.15 + 0.1 * sin(fi * 3.14);
        float cell = smoothstep(size, size * 0.7, d);
        float shade = sqrt(max(1.0 - d * d / (size * size + 0.001), 0.0));
        col_val += cell * shade;
    }
    col_val = min(col_val, 1.0);
    vec3 col = vec3(0.05, 0.05, 0.1);
    col += vec3(0.4, 0.2, 0.6) * col_val;
    col += vec3(0.3, 0.5, 0.9) * col_val * col_val;
    fragColor = vec4(col, 1.0);
}
