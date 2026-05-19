#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mosaic tile floor pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Diamond (45-degree rotated square) within each cell
    float diamond = abs(fp.x - 0.5) + abs(fp.y - 0.5);
    float is_inner = smoothstep(0.5, 0.48, diamond);
    
    // Corner triangles (the outer parts)
    float is_outer = 1.0 - is_inner;
    
    // Color based on position (tessellation coloring)
    float h1 = hash(id);
    float h2 = hash(id + vec2(1.0, 0.0));
    float h3 = hash(id + vec2(0.0, 1.0));
    float h4 = hash(id + vec2(1.0, 1.0));
    
    // Quadrant colors (each corner triangle gets a different color)
    float q1 = step(fp.x + fp.y, 1.0); // top-left triangle
    float q2 = step(fp.y, fp.x);        // bottom-right vs top-left
    
    vec3 col_a = mix(vec3(0.7, 0.15, 0.12), vec3(0.75, 0.2, 0.15), h1);
    vec3 col_b = mix(vec3(0.15, 0.5, 0.2), vec3(0.2, 0.55, 0.25), h2);
    vec3 col_c = mix(vec3(0.15, 0.2, 0.6), vec3(0.2, 0.25, 0.65), h3);
    vec3 col_d = mix(vec3(0.85, 0.75, 0.3), vec3(0.9, 0.8, 0.35), h4);
    
    // Inner diamond gets one color, corners get adjacent colors
    vec3 col = mix(col_a, col_d, is_inner);
    col = mix(col, col_b, is_outer * q1);
    col = mix(col, col_c, is_outer * (1.0 - q1));
    
    // Grout lines
    float grout = 1.0 - step(0.02, fp.x) * step(fp.x, 0.98) *
                          step(0.02, fp.y) * step(fp.y, 0.98);
    col = mix(col, vec3(0.6, 0.58, 0.5), grout);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
