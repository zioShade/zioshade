#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Flame fractal (Julia set variant)
    vec2 z = uv * 1.5;
    float col_val = 0.0;
    for (int i = 0; i < 12; i++) {
        // Sinusoidal variant
        z = vec2(sin(z.x), cos(z.y)) * 1.2 + uv * 0.5;
        col_val += exp(-length(z) * 2.0);
    }
    col_val = col_val / 12.0;
    vec3 col = vec3(
        min(col_val * 3.0, 1.0),
        min(col_val * 1.5, 1.0),
        min(col_val * 0.5, 1.0)
    );
    fragColor = vec4(col, 1.0);
}
