#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Penrose-style tiling approximation
void main() {
    vec2 p = uv * 6.0;
    
    // Rhombus tiling
    float angle = 0.5236;  // 30 degrees
    float c = cos(angle);
    float s = sin(angle);
    
    // Two skewed grids
    vec2 g1 = vec2(p.x + p.y * c, p.y * s);
    vec2 g2 = vec2(p.x - p.y * c, p.y * s);
    
    // Alternating cells
    float cell1 = mod(floor(g1.x) + floor(g1.y), 3.0);
    float cell2 = mod(floor(g2.x) + floor(g2.y), 3.0);
    
    float pattern = cell1 + cell2;
    pattern = fract(pattern / 5.0);
    
    vec3 col = vec3(pattern, pattern * 0.7, 1.0 - pattern * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
