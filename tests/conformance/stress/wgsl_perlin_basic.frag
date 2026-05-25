// Tests: perlin-like noise with interpolation
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

float hash2d(vec2 p) {
    return fract(sin(dot(p, vec2(41.1, 289.7))) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec2 grid = floor(uv * 8.0);
    vec2 frac_uv = fract(uv * 8.0);
    float h00 = hash2d(grid);
    float h10 = hash2d(grid + vec2(1.0, 0.0));
    float h01 = hash2d(grid + vec2(0.0, 1.0));
    float h11 = hash2d(grid + vec2(1.0, 1.0));
    float h = mix(mix(h00, h10, frac_uv.x), mix(h01, h11, frac_uv.x), frac_uv.y);
    vec3 color = mix(vec3(0.1, 0.2, 0.3), vec3(0.8, 0.7, 0.5), h);
    fragColor = vec4(color, 1.0);
}
