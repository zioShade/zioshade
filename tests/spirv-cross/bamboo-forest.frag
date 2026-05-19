#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test bamboo forest with depth layering
void main() {
    // Sky
    vec3 col = mix(vec3(0.6, 0.7, 0.5), vec3(0.3, 0.5, 0.35), uv.y);
    
    // Multiple bamboo stalks at different depths
    float stalks = 0.0;
    vec3 stalk_col = vec3(0.45, 0.6, 0.25);
    vec3 stalk_dark = vec3(0.25, 0.4, 0.15);
    
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        float x = fract(sin(fi * 7.3) * 43.7);
        float depth = fract(cos(fi * 3.1) * 17.9);
        float width = mix(0.008, 0.02, depth);
        float brightness = mix(0.5, 1.0, depth);
        
        // Stalk
        float stalk = smoothstep(width, width - 0.002, abs(uv.x - x));
        stalk *= step(0.05, uv.y);
        
        // Segments (nodes)
        float seg_len = 0.08 + depth * 0.04;
        float seg_y = mod(uv.y, seg_len);
        float node = smoothstep(0.005, 0.002, abs(seg_y)) * stalk;
        
        // Branch at some nodes
        float branch_y = floor(uv.y / seg_len) * seg_len + seg_len * 0.5;
        float has_branch = step(0.6, fract(sin(fi * 13.7 + floor(uv.y / seg_len)) * 100.0));
        float branch_dir = step(0.5, fract(cos(fi * 5.3) * 50.0)) * 2.0 - 1.0;
        float bx = x + branch_dir * 0.05;
        float branch = smoothstep(0.003, 0.001, abs((uv.y - branch_y) - (uv.x - x) * (-branch_dir * 2.0)));
        branch *= step(0.0, (uv.x - x) * branch_dir) * smoothstep(0.12, 0.08, abs(uv.x - x));
        branch *= has_branch * stalk;
        
        // Leaves (small ellipses at branch tips)
        float leaf_x = x + branch_dir * 0.06;
        float leaf_y = branch_y + 0.01;
        float ld = length((uv - vec2(leaf_x, leaf_y)) * vec2(0.5, 1.0));
        float leaf = smoothstep(0.015, 0.01, ld) * has_branch * stalk;
        
        vec3 this_col = mix(stalk_dark, stalk_col, brightness);
        col = mix(col, this_col, stalk * (1.0 - node));
        col += node * vec3(0.3, 0.4, 0.2) * stalk;
        col += branch * this_col * 0.8;
        col += leaf * vec3(0.3, 0.55, 0.15);
    }
    
    // Ground
    float ground = smoothstep(0.08, 0.06, uv.y);
    col = mix(col, vec3(0.2, 0.3, 0.12), ground);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
