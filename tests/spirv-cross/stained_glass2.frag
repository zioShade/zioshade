#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Stained glass with thick lead lines
    float scale = 2.5;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Diamond shape
    float d = abs(f.x - 0.5) + abs(f.y - 0.5);
    float diamond = smoothstep(0.35, 0.3, d);
    // Inner circle
    float circle = smoothstep(0.15, 0.12, length(f - 0.5));
    // Color
    vec3 glass1 = vec3(0.7, 0.2, 0.15);
    vec3 glass2 = vec3(0.1, 0.2, 0.6);
    vec3 glass3 = vec3(0.9, 0.8, 0.2);
    vec3 glass = h < 0.33 ? glass1 : h < 0.67 ? glass2 : glass3;
    float shape = max(diamond, circle);
    // Lead border
    float edge = min(min(f.x, 1.0-f.x), min(f.y, 1.0-f.y));
    vec3 col = mix(vec3(0.05), glass, shape) * (0.7 + 0.3 * smoothstep(0.06, 0.1, edge));
    col = mix(col, vec3(0.08), smoothstep(0.04, 0.02, edge));
    fragColor = vec4(col, 1.0);
}
