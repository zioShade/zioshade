#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Persian rug pattern
    float scale = 3.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Multiple border levels
    float border = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float b1 = smoothstep(0.05, 0.03, abs(border - 0.45));
    float b2 = smoothstep(0.03, 0.01, abs(border - 0.35));
    float b3 = smoothstep(0.03, 0.01, abs(border - 0.1));
    // Central medallion
    vec2 center = vec2(0.5);
    float d = length(f - center);
    float medallion = smoothstep(0.25, 0.2, d) * (1.0 - smoothstep(0.15, 0.1, d));
    // Corner motifs
    float corner = 1.0 - smoothstep(0.15, 0.12, length(f - vec2(0.0)));
    vec3 deep_red = vec3(0.6, 0.1, 0.05);
    vec3 navy = vec3(0.05, 0.05, 0.3);
    vec3 gold = vec3(0.85, 0.7, 0.2);
    vec3 ivory = vec3(0.95, 0.92, 0.85);
    vec3 col = deep_red;
    col = mix(col, navy, b1);
    col = mix(col, gold, b2 + b3);
    col = mix(col, ivory, medallion);
    col = mix(col, gold, corner * 0.5);
    fragColor = vec4(col, 1.0);
}
