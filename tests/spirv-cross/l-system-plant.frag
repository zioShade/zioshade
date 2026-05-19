#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test L-system plant with iterative branching
void main() {
    vec3 col = vec3(0.92, 0.9, 0.85);
    
    // Ground
    float ground = smoothstep(0.15, 0.13, uv.y);
    col = mix(col, vec3(0.6, 0.5, 0.35), ground);
    
    // Draw plant using iterative line segments
    vec3 stem_col = vec3(0.3, 0.5, 0.15);
    vec3 leaf_col = vec3(0.2, 0.6, 0.1);
    
    // Main stem
    float stem = smoothstep(0.006, 0.003, abs(uv.x - 0.5)) * step(0.15, uv.y) * step(uv.y, 0.55);
    col = mix(col, stem_col, stem);
    
    // Branch pairs at multiple levels
    for (int level = 0; level < 4; level++) {
        float fl = float(level);
        float branch_y = 0.3 + fl * 0.07;
        float branch_len = 0.12 - fl * 0.02;
        float branch_w = 0.004 - fl * 0.0005;
        
        // Left branch
        float lx = uv.x - 0.5 + (uv.y - branch_y) * 0.7;
        float left = smoothstep(branch_w, branch_w - 0.001, abs(lx)) * step(branch_y, uv.y) * step(uv.y, branch_y + branch_len);
        
        // Right branch
        float rx = uv.x - 0.5 - (uv.y - branch_y) * 0.7;
        float right = smoothstep(branch_w, branch_w - 0.001, abs(rx)) * step(branch_y, uv.y) * step(uv.y, branch_y + branch_len);
        
        col = mix(col, stem_col, max(left, right));
        
        // Leaf at tip
        float leaf_y = branch_y + branch_len;
        float left_leaf_x = 0.5 - branch_len * 0.7;
        float right_leaf_x = 0.5 + branch_len * 0.7;
        
        float ld1 = length((uv - vec2(left_leaf_x, leaf_y)) * vec2(1.5, 1.0));
        float ld2 = length((uv - vec2(right_leaf_x, leaf_y)) * vec2(1.5, 1.0));
        float leaf1 = smoothstep(0.02, 0.012, ld1);
        float leaf2 = smoothstep(0.02, 0.012, ld2);
        
        col = mix(col, leaf_col, max(leaf1, leaf2));
    }
    
    // Flower at top
    float flower_y = 0.55;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float pa = fi * 1.0472 - 1.5708;
        vec2 petal_center = vec2(0.5, flower_y) + vec2(cos(pa), sin(pa)) * 0.025;
        float pd = length((uv - petal_center) * vec2(0.6, 1.0));
        float petal = smoothstep(0.018, 0.012, pd);
        col = mix(col, vec3(0.95, 0.5, 0.7), petal);
    }
    
    // Flower center
    float fc = smoothstep(0.012, 0.008, length(uv - vec2(0.5, flower_y)));
    col = mix(col, vec3(0.95, 0.85, 0.2), fc);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
