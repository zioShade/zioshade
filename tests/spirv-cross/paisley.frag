#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Paisley pattern
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Teardrop shape
    float dx = f.x - 0.5;
    float dy = f.y - 0.3;
    float d = length(vec2(dx, dy));
    float tear_top = smoothstep(0.25, 0.22, d + abs(dx) * 0.3);
    // Curved tail
    float tail_x = f.x - 0.5 - 0.2 * sin(f.y * 3.14159);
    float tail = smoothstep(0.04, 0.02, abs(tail_x)) * step(f.y, 0.3);
    float shape = max(tear_top, tail);
    // Detail inside
    float inner = sin(atan(dy, dx) * 6.0 + d * 15.0) * 0.5 + 0.5;
    vec3 bg = vec3(0.95, 0.92, 0.85);
    vec3 pattern_col = vec3(0.7, 0.15, 0.1);
    vec3 detail = vec3(0.9, 0.7, 0.1);
    vec3 col = mix(bg, pattern_col, shape);
    col = mix(col, detail, shape * inner * 0.4);
    fragColor = vec4(col, 1.0);
}
