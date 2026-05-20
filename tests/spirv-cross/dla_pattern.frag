#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Diffusion-limited aggregation pattern
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Dendritic branching pattern
    float branch = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float angle = fi * 1.047;
        float spread = sin(a * 3.0 + fi * 2.0) * 0.15;
        float d = abs(r - 0.3 - spread - fi * 0.05);
        float thickness = 0.015 / (fi * 0.5 + 1.0);
        branch = max(branch, smoothstep(thickness, 0.0, d) * step(abs(a - angle), 0.3));
    }
    vec3 col = vec3(0.05, 0.05, 0.1) + vec3(0.4, 0.8, 0.6) * branch;
    fragColor = vec4(col, 1.0);
}
