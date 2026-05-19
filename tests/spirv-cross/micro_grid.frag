#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 20.0;
    vec2 grid = abs(fract(uv) - 0.5);
    float line = min(grid.x, grid.y);
    float col = smoothstep(0.0, 0.05, line);
    gl_FragColor = vec4(col, col * 0.8, col * 0.6, 1.0);
}
