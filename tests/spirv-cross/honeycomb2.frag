#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Honeycomb lattice (proper hex grid v2)
    float s = 1.5;
    vec2 p = uv / s;
    // Hex grid
    vec2 h1 = p;
    vec2 h2 = p - vec2(0.5, 0.289);
    float r1 = length(fract(h1) - 0.5);
    float r2 = length(fract(h2) - 0.5);
    float d = min(r1, r2);
    float hex = smoothstep(0.35, 0.32, d);
    float n = fract(sin(dot(floor(p), vec2(127.1, 311.7))) * 43758.5);
    vec3 honey = vec3(0.85, 0.7, 0.2) * hex * (0.8 + 0.2 * n);
    vec3 bg = vec3(0.1, 0.1, 0.08);
    vec3 col = mix(bg, honey, hex);
    fragColor = vec4(col, 1.0);
}
