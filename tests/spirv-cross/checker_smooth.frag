#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Checkerboard
    vec2 grid = floor(uv);
    float checker = mod(grid.x + grid.y, 2.0);
    // Smooth checkerboard
    vec2 smooth_grid = fract(uv);
    float edge = smoothstep(0.0, 0.05, min(smooth_grid.x, smooth_grid.y));
    float pattern = mix(checker, 0.5, 1.0 - edge);
    vec3 col = mix(vec3(0.2), vec3(0.8), pattern);
    fragColor = vec4(col, 1.0);
}
