#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test amethyst gemstone with facets
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Hexagonal gem outline
    float hex = cos(a * 3.0) * 0.5 + 0.5;
    float hex_r = mix(0.4, 0.35, hex);
    float gem = smoothstep(hex_r + 0.01, hex_r, r);
    
    // Facet shading: 6 triangular facets
    float facet_id = floor(mod(a / 1.0472 + 0.5, 6.0));
    float facet_shade = 0.3 + 0.12 * facet_id;
    
    // Purple amethyst color with facet variation
    vec3 purple = vec3(0.4, 0.15, 0.6) * facet_shade;
    
    // Table facet (flat top)
    float table = smoothstep(0.15, 0.13, r);
    vec3 table_col = vec3(0.55, 0.25, 0.75);
    
    // Star facets (triangles from table to edge)
    float star = 0.0;
    for (int i = 0; i < 6; i++) {
        float fa = float(i) * 1.0472;
        float diff = abs(a - fa);
        diff = min(diff, 6.2832 - diff);
        float star_line = smoothstep(0.04, 0.015, diff) * step(0.15, r) * smoothstep(hex_r, hex_r - 0.02, r);
        star += star_line;
    }
    
    // Highlight
    float hl = exp(-dot(p - vec2(-0.08, -0.08), p - vec2(-0.08, -0.08)) * 25.0) * gem * 0.4;
    
    vec3 col = vec3(0.05);
    col = mix(col, purple, gem);
    col = mix(col, table_col, table);
    col += min(star, 1.0) * vec3(0.6, 0.3, 0.8) * gem;
    col += hl;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
