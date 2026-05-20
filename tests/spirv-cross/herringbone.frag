#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Herringbone parquet floor
    float scale = 2.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Herringbone: alternating 45-degree oriented rectangles
    float h = mod(cell.x + cell.y, 2.0);
    float d1 = abs(f.x - f.y); // diagonal 1
    float d2 = abs(f.x + f.y - 1.0); // diagonal 2
    float stripe = h > 0.5 ? d1 : d2;
    float plank = smoothstep(0.05, 0.03, stripe);
    // Wood color variation
    float n = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    vec3 light_wood = vec3(0.75, 0.55, 0.3);
    vec3 dark_wood = vec3(0.5, 0.35, 0.15);
    vec3 col = mix(dark_wood, light_wood, n) * (0.8 + 0.2 * plank);
    fragColor = vec4(col, 1.0);
}
