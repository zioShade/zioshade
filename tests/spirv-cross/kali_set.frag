#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Kali set fractal
    vec2 z = uv;
    float col_val = 0.0;
    for (int i = 0; i < 8; i++) {
        z = abs(z) / dot(z, z) - vec2(0.8, 0.3);
        col_val += length(z);
    }
    col_val = col_val / 8.0;
    vec3 col = vec3(
        sin(col_val * 3.0) * 0.5 + 0.5,
        sin(col_val * 3.0 + 1.0) * 0.5 + 0.5,
        sin(col_val * 3.0 + 2.0) * 0.5 + 0.5
    );
    fragColor = vec4(col, 1.0);
}
