#version 450

// Test: procedural checkerboard with rotation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float angle = 0.3;
    vec2 ruv = vec2(
        uv.x * cos(angle) - uv.y * sin(angle),
        uv.x * sin(angle) + uv.y * cos(angle)
    );
    vec2 grid = floor(ruv * 6.0);
    float checker = mod(grid.x + grid.y, 2.0);
    vec3 col = mix(vec3(0.9, 0.85, 0.8), vec3(0.2, 0.25, 0.3), checker);
    gl_FragColor = vec4(col, 1.0);
}
