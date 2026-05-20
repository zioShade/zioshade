#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Pac-Man maze approximation
    float scale = 10.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Walls where h > 0.5
    float is_wall = step(0.5, h);
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float wall_border = is_wall * smoothstep(0.1, 0.08, edge);
    // Path is non-wall area
    vec3 wall_col = vec3(0.1, 0.1, 0.7) * is_wall;
    vec3 path_col = vec3(0.0);
    vec3 col = mix(path_col, wall_col, 1.0 - wall_border * 0.3);
    // Pac-Man character
    float pac_r = length(uv - vec2(-0.3, -0.2));
    float pac_a = atan(uv.y + 0.2, uv.x + 0.3);
    float mouth = step(0.3, abs(pac_a));
    float pac = smoothstep(0.12, 0.1, pac_r) * mouth;
    col = mix(col, vec3(1.0, 0.9, 0.0), pac);
    fragColor = vec4(col, 1.0);
}
