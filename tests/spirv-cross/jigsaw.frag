#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Jigsaw puzzle pieces
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Edge distance
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    // Puzzle tab bumps on each edge
    float tab_r = 0.5; // which edges have tabs
    float tab_top = smoothstep(0.2, 0.18, length(vec2(f.x - 0.5, f.y - 1.0 + 0.12))) * step(0.5, h);
    float tab_bot = smoothstep(0.2, 0.18, length(vec2(f.x - 0.5, f.y - 0.12))) * step(0.5, fract(h * 2.0));
    float tab = max(tab_top, tab_bot);
    float border = smoothstep(0.06, 0.03, edge) + tab;
    border = min(border, 1.0);
    float piece_h = fract(sin(dot(cell, vec2(74.2, 51.3))) * 43758.5);
    vec3 col = vec3(0.85) * (0.6 + 0.4 * piece_h);
    col = mix(col, vec3(0.1), border);
    fragColor = vec4(col, 1.0);
}
