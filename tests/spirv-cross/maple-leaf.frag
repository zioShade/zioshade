#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test maple leaf pattern
void main() {
    vec2 p = uv - vec2(0.5, 0.48);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Background
    vec3 col = vec3(0.95, 0.93, 0.88);
    
    // Maple leaf shape: 5 lobes with sinusoidal edges
    float lobe = 0.0;
    // Main lobe (top)
    float main_lobe = cos(a - 1.5708) * 0.15 + 0.05;
    main_lobe = max(main_lobe, 0.0);
    
    // Side lobes
    float side_r = cos(a - 0.3) * 0.12 + 0.03;
    side_r = max(side_r, 0.0);
    float side_l = cos(a - 2.8) * 0.12 + 0.03;
    side_l = max(side_l, 0.0);
    
    // Lower lobes
    float lower_r = cos(a + 0.8) * 0.08 + 0.02;
    lower_r = max(lower_r, 0.0);
    float lower_l = cos(a + 2.3) * 0.08 + 0.02;
    lower_l = max(lower_l, 0.0);
    
    float leaf_r = max(max(max(main_lobe, side_r), max(side_l, lower_r)), lower_l);
    
    // Stem
    float stem = smoothstep(0.008, 0.003, abs(p.x + p.y * 0.1)) * step(r, 0.2) * step(0.0, -p.y + 0.05);
    
    float leaf = smoothstep(leaf_r + 0.005, leaf_r - 0.005, r);
    
    // Autumn colors
    vec3 leaf_col = vec3(0.85, 0.35, 0.05);
    float color_var = sin(a * 3.0) * 0.5 + 0.5;
    leaf_col = mix(leaf_col, vec3(0.9, 0.6, 0.1), color_var);
    leaf_col = mix(leaf_col, vec3(0.7, 0.15, 0.05), smoothstep(0.12, 0.05, r));
    
    // Veins
    float veins = 0.0;
    for (int i = 0; i < 5; i++) {
        float va = float(i) * 1.2566 - 1.5708 + 0.6283;
        float diff = abs(a - va);
        diff = min(diff, 6.2832 - diff);
        veins += smoothstep(0.04, 0.02, diff) * leaf;
    }
    
    col = mix(col, leaf_col, leaf);
    col = mix(col, leaf_col * 0.7, min(veins, 1.0));
    col = mix(col, vec3(0.45, 0.3, 0.1), stem);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
