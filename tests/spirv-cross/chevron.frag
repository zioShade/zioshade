#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test chevron / herringbone pattern
void main() {
    vec2 p = uv * 10.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Chevron: V-shapes in alternating rows
    float row = mod(id.y, 2.0);
    
    // Zigzag line
    float zigzag;
    if (row < 1.0) {
        zigzag = abs(fp.x - 0.5 + fp.y * 0.5);
    } else {
        zigzag = abs(fp.x - 0.5 - fp.y * 0.5);
    }
    
    // Thin line along the zigzag
    float line = smoothstep(0.06, 0.04, zigzag);
    
    // Fill above/below the zigzag
    float above = smoothstep(0.0, 0.1, zigzag);
    
    // Colors
    vec3 col1 = vec3(0.2, 0.4, 0.6);
    vec3 col2 = vec3(0.6, 0.3, 0.2);
    vec3 line_col = vec3(0.9, 0.85, 0.75);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    vec3 tile_col = mix(col1, col2, h);
    
    vec3 col = mix(line_col, tile_col, above);
    col = mix(col, line_col, line * 0.8);
    
    // Subtle border between tiles
    float border = 1.0 - step(0.02, fp.x) * step(fp.x, 0.98) *
                           step(0.02, fp.y) * step(fp.y, 0.98);
    col = mix(col, col1 * 0.5, border * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
