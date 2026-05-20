#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Ripple effect (concentric waves from click point)
    float r = length(uv - vec2(0.2, -0.1));
    float wave = sin(r * 25.0) * exp(-r * 3.0) * 0.5;
    // Color modulation
    vec3 base = vec3(0.1, 0.15, 0.3);
    vec3 highlight = vec3(0.4, 0.7, 1.0);
    vec3 col = base + highlight * max(wave, 0.0);
    col += vec3(0.2, 0.1, 0.3) * max(-wave, 0.0);
    fragColor = vec4(col, 1.0);
}
