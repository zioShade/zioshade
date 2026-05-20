#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Chain-link fence with perspective
    float scale = 3.0;
    vec2 p = uv * scale;
    // Diamond grid
    vec2 cell = floor(p + 0.5);
    vec2 f = fract(p + 0.5) - 0.5;
    float d1 = abs(f.x - f.y);
    float d2 = abs(f.x + f.y);
    float wire = min(d1, d2);
    float link = smoothstep(0.08, 0.05, wire);
    // Twist at crossings
    float over_under = step(0.5, fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5));
    vec3 metal_light = vec3(0.6, 0.6, 0.62);
    vec3 metal_dark = vec3(0.35, 0.35, 0.38);
    vec3 bg = vec3(0.3, 0.5, 0.2);
    vec3 col = bg;
    col = mix(col, metal_dark, link);
    col = mix(col, metal_light, link * 0.3 * (over_under > 0.5 ? step(0.0, f.x) : step(f.x, 0.0)));
    fragColor = vec4(col, 1.0);
}
