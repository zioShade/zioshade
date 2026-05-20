#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Glazed ceramic pattern
    float scale = 4.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Repeated motif in each tile
    float cx = f.x - 0.5;
    float cy = f.y - 0.5;
    float angle = atan(cy, cx);
    float dist = length(vec2(cx, cy));
    float motif = sin(angle * 4.0 + dist * 10.0) * 0.5 + 0.5;
    vec3 blue = vec3(0.15, 0.3, 0.6);
    vec3 white = vec3(0.95, 0.93, 0.88);
    vec3 col = mix(blue, white, motif) * (0.8 + 0.2 * h);
    // Grout lines
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    col = mix(col, vec3(0.6, 0.6, 0.58), smoothstep(0.04, 0.02, edge));
    fragColor = vec4(col, 1.0);
}
