#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Cross-stitch / embroidery pattern
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Cross stitch: X pattern in each cell
    float d1 = abs(f.x - f.y);
    float d2 = abs(f.x + f.y - 1.0);
    float cross = smoothstep(0.1, 0.06, min(d1, d2));
    // Pattern: checkerboard of different colors
    float checker = mod(cell.x + cell.y, 2.0);
    vec3 red = vec3(0.8, 0.15, 0.1);
    vec3 blue = vec3(0.1, 0.2, 0.7);
    vec3 fabric = vec3(0.95, 0.92, 0.85);
    vec3 stitch = checker > 0.5 ? red : blue;
    vec3 col = mix(fabric, stitch, cross);
    fragColor = vec4(col, 1.0);
}
