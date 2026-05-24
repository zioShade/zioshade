#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Checkerboard with varying scale
    float scale = 10.0;
    vec2 grid = floor(uv * scale);
    float checker = mod(grid.x + grid.y, 2.0);

    // Anti-aliased edge
    vec2 f = fract(uv * scale);
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    float aa = smoothstep(0.0, 0.05, edge);

    vec3 black = vec3(0.1);
    vec3 white = vec3(0.9);
    vec3 color = mix(black, white, checker) * aa;

    // Vignette
    float vig = 1.0 - length(uv - 0.5) * 1.2;
    vig = clamp(vig, 0.0, 1.0);
    color *= vig;

    fragColor = vec4(color, 1.0);
}
