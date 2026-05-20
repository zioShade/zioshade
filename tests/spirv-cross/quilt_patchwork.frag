#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Quilt patchwork with random fabrics
    float scale = 2.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    
    vec3 col;
    if (h < 0.25) {
        // Polka dots
        float dot_d = length(f - 0.5);
        col = mix(vec3(0.8, 0.3, 0.3), vec3(1.0), smoothstep(0.15, 0.1, dot_d));
    } else if (h < 0.5) {
        // Stripes
        float stripe = sin(f.x * 15.0) * 0.5 + 0.5;
        col = mix(vec3(0.2, 0.3, 0.7), vec3(0.7, 0.8, 1.0), step(0.5, stripe));
    } else if (h < 0.75) {
        // Simple solid with texture
        float tex = sin(f.x * 10.0) * sin(f.y * 10.0) * 0.5 + 0.5;
        col = mix(vec3(0.6, 0.5, 0.3), vec3(0.9, 0.85, 0.7), tex);
    } else {
        // Solid color with border
        float edge = min(min(f.x, 1.0-f.x), min(f.y, 1.0-f.y));
        col = mix(vec3(0.3, 0.6, 0.3), vec3(0.2, 0.4, 0.2), smoothstep(0.1, 0.05, edge));
    }
    
    // Stitching between patches
    float edge = min(min(f.x, 1.0-f.x), min(f.y, 1.0-f.y));
    col = mix(col, vec3(0.6, 0.55, 0.5), smoothstep(0.02, 0.01, edge));
    
    fragColor = vec4(col, 1.0);
}
