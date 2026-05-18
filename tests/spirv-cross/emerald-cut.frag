#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test emerald-cut gemstone with facets
void main() {
    vec2 p = uv - 0.5;
    
    // Rectangular gem outline (emerald cut)
    float dx = abs(p.x);
    float dy = abs(p.y);
    
    // Outer bezel facets
    float bezel = step(dx, 0.35) * step(dy, 0.4);
    
    // Inner table facet (top flat area)
    float table = step(dx, 0.2) * step(dy, 0.25);
    
    // Pavilion facets (angled inner area)
    float pavilion_x = smoothstep(0.2, 0.35, dx) * bezel;
    float pavilion_y = smoothstep(0.25, 0.4, dy) * bezel;
    float pavilion = max(pavilion_x, pavilion_y) * (1.0 - table);
    
    // Step facets (concentric rectangles)
    float step1 = smoothstep(0.005, 0.0, abs(dx - 0.25)) * bezel;
    float step2 = smoothstep(0.005, 0.0, abs(dx - 0.3)) * bezel;
    float step3 = smoothstep(0.005, 0.0, abs(dy - 0.3)) * bezel;
    float step4 = smoothstep(0.005, 0.0, abs(dy - 0.35)) * bezel;
    
    // Color: green emerald with facet-dependent brightness
    vec3 emerald = vec3(0.1, 0.6, 0.3);
    vec3 light = vec3(0.2, 0.85, 0.45);
    vec3 dark = vec3(0.05, 0.3, 0.15);
    
    vec3 col = vec3(0.03);
    col += table * light;
    col += pavilion * emerald;
    col += (1.0 - bezel) * 0.0;
    
    // Facet lines
    float facets = step1 + step2 + step3 + step4;
    col = mix(col, dark, facets * bezel * 0.5);
    
    // Highlight on table
    float hl = exp(-dot(p - vec2(-0.08, -0.1), p - vec2(-0.08, -0.1)) * 30.0);
    col += hl * table * 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
