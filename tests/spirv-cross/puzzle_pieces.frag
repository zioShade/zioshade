#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Interlocking puzzle pieces
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float edge_dist = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    // Puzzle tabs
    float tab_h = step(0.4, f.y) * (1.0 - step(0.6, f.y));
    float tab_right = tab_h * smoothstep(0.4, 0.38, abs(f.x - 1.0)) * step(0.5, fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5));
    float tab_left = tab_h * smoothstep(0.4, 0.38, f.x) * step(0.5, fract(sin(dot(cell + vec2(1.0, 0.0), vec2(127.1, 311.7))) * 43758.5));
    float border = smoothstep(0.06, 0.03, edge_dist) + tab_right + tab_left;
    border = min(border, 1.0);
    float h = fract(sin(dot(cell, vec2(74.2, 51.3))) * 43758.5);
    vec3 col = vec3(0.9) * (0.7 + 0.3 * h);
    col = mix(col, vec3(0.1), border);
    fragColor = vec4(col, 1.0);
}
