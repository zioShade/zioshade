#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.03;
    // Lattice pattern
    vec2 grid = abs(fract(uv) - 0.5);
    float d = min(grid.x, grid.y);
    float line = smoothstep(0.05, 0.02, d);
    float diag = abs(grid.x - grid.y);
    float diag_line = smoothstep(0.05, 0.02, diag);
    float pattern = max(line, diag_line * 0.5);
    vec3 col = mix(vec3(0.15), vec3(0.7, 0.8, 0.6), pattern);
    fragColor = vec4(col, 1.0);
}
