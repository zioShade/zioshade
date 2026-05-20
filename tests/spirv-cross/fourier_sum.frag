#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sine wave superposition (Fourier-like)
    float sum = 0.0;
    for (int i = 1; i <= 6; i++) {
        float fi = float(i);
        sum += sin(uv.x * fi * 5.0 + fi * 0.5) / fi;
    }
    float d = abs(uv.y - sum * 0.15);
    float line = smoothstep(0.01, 0.005, d);
    float glow = smoothstep(0.04, 0.01, d) * 0.2;
    vec3 col = vec3(0.02) + vec3(0.2, 0.6, 1.0) * (line + glow);
    fragColor = vec4(col, 1.0);
}
