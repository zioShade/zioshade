#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Wrought iron fence pattern
    float scale = 6.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Vertical bars
    float bar = smoothstep(0.08, 0.05, abs(f.x - 0.5));
    // Decorative scrollwork
    float scroll_r = length(f - vec2(0.5, 0.5));
    float scroll = smoothstep(0.3, 0.28, scroll_r) * (1.0 - smoothstep(0.22, 0.2, scroll_r));
    // Spear points at top
    float spear_h = 0.7 + 0.3 * (1.0 - abs(f.x - 0.5) * 5.0);
    float spear = smoothstep(0.02, 0.01, abs(f.y - spear_h)) * bar;
    // Horizontal rails
    float rail1 = smoothstep(0.04, 0.02, abs(f.y - 0.25));
    float rail2 = smoothstep(0.04, 0.02, abs(f.y - 0.75));
    float iron = max(max(bar, scroll), max(spear, rail1 + rail2));
    iron = min(iron, 1.0);
    vec3 col = vec3(0.3, 0.3, 0.35) * iron;
    col += vec3(0.8, 0.7, 0.5) * (1.0 - iron);
    fragColor = vec4(col, 1.0);
}
