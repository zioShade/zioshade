#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test oriental rug pattern with nested borders
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv;
    
    // Outer border
    float border1 = step(0.05, p.x) * step(p.x, 0.95) *
                    step(0.05, p.y) * step(p.y, 0.95);
    float border1_edge = 1.0 - border1;
    
    // Inner border
    float border2 = step(0.12, p.x) * step(p.x, 0.88) *
                    step(0.12, p.y) * step(p.y, 0.88);
    float border_band = border1 * (1.0 - border2);
    
    // Field
    float field = border2;
    
    // Border pattern: zigzag
    float bz = sin((p.x + p.y) * 60.0) * 0.5 + 0.5;
    float border_pat = step(0.5, bz);
    
    // Field pattern: 8-pointed stars in grid
    vec2 fp = fract(p * 8.0);
    float a = atan(fp.y - 0.5, fp.x - 0.5);
    float sr = length(fp - 0.5);
    float star = cos(a * 4.0) * 0.12 + 0.2;
    float star_fill = smoothstep(star, star - 0.02, sr);
    
    // Medallion in center
    vec2 cp = p - 0.5;
    float cr = length(cp);
    float ca = atan(cp.y, cp.x);
    float medallion = smoothstep(0.18, 0.16, cr);
    float med_ring = smoothstep(0.2, 0.18, cr) * (1.0 - smoothstep(0.15, 0.13, cr));
    float med_detail = sin(ca * 12.0) * 0.5 + 0.5;
    
    // Colors
    vec3 border_col = mix(vec3(0.6, 0.15, 0.1), vec3(0.8, 0.7, 0.3), border_pat);
    vec3 field_col = vec3(0.7, 0.15, 0.15);
    vec3 star_col = vec3(0.9, 0.8, 0.4);
    vec3 med_col = vec3(0.15, 0.3, 0.6);
    vec3 med_detail_col = vec3(0.8, 0.7, 0.3);
    
    vec3 col = vec3(0.3, 0.1, 0.05); // fringe
    col = mix(col, border_col, border_band);
    col = mix(col, field_col, field * (1.0 - star_fill) * (1.0 - medallion));
    col = mix(col, star_col, star_fill * field);
    col = mix(col, med_col, medallion);
    col = mix(col, med_detail_col, med_ring * med_detail);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
