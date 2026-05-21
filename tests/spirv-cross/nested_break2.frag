#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 col = vec3(0.0);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 center = vec2(cos(fi * 1.256) * 0.5, sin(fi * 1.256) * 0.5);
        float d = length(uv - center);
        if (d < 0.05) continue;
        for (int j = 0; j < 3; j++) {
            float fj = float(j);
            float ring = abs(d - 0.1 - fj * 0.08);
            float line = smoothstep(0.01, 0.005, ring);
            col += vec3(line * 0.15) / (fi + 1.0);
            if (ring < 0.005) break;
        }
        col += vec3(0.05 / (d + 0.1)) / (fi + 1.0);
    }
    fragColor = vec4(min(col, vec3(1.0)), 1.0);
}
