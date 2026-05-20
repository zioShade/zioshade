#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.003;
    // Brick wall pattern
    vec2 brick_size = vec2(2.0, 1.0);
    float row = floor(uv.y / brick_size.y);
    float offset = mod(row, 2.0) * brick_size.x * 0.5;
    vec2 brick_uv = vec2(uv.x - offset, uv.y);
    vec2 brick_id = floor(brick_uv / brick_size);
    vec2 brick_f = fract(brick_uv / brick_size);
    float mortar = smoothstep(0.05, 0.03, min(brick_f.x, brick_f.y));
    mortar += smoothstep(0.05, 0.03, min(1.0 - brick_f.x, 1.0 - brick_f.y));
    mortar = min(mortar, 1.0);
    float h = fract(sin(dot(brick_id, vec2(127.1, 311.7))) * 43758.5453);
    vec3 brick = mix(vec3(0.6, 0.3, 0.2), vec3(0.7, 0.4, 0.3), h);
    vec3 col = mix(brick, vec3(0.7, 0.7, 0.65), mortar);
    fragColor = vec4(col, 1.0);
}
