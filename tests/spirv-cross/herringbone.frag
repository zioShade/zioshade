#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test herringbone tile pattern
void main() {
    vec2 p = uv * 12.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Alternate column offset
    float col_offset = mod(id.x, 2.0) * 0.5;
    fp.y = fract(fp.y + col_offset);
    
    // Two rectangles per cell forming the zigzag
    float r1 = step(0.1, fp.x) * step(fp.x, 0.9) *
               step(0.1, fp.y) * step(fp.y, 0.4);
    float r2 = step(0.1, fp.x) * step(fp.x, 0.4) *
               step(0.1, fp.y) * step(fp.y, 0.9);
    
    float tile = max(r1, r2);
    
    // Color per tile
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    vec3 col1 = vec3(0.7, 0.5, 0.3);
    vec3 col2 = vec3(0.5, 0.35, 0.2);
    vec3 tile_col = mix(col1, col2, h);
    
    vec3 col = vec3(0.08) + tile * tile_col;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
