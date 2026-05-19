#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Barnsley fern using iterative point accumulation
void main() {
    // Approximate Barnsley fern using distance fields
    vec2 p = uv - vec2(0.5, 0.0);
    p.y *= 1.5;
    
    float fern = 0.0;
    float scale = 1.0;
    
    // Multiple iterations of self-similar fern segments
    for (int iter = 0; iter < 5; iter++) {
        // Main stem
        float stem = smoothstep(0.01 * scale, 0.005 * scale, abs(p.x));
        float stem_range = step(0.0, p.y) * smoothstep(0.0 + float(iter) * 0.15, 0.01 + float(iter) * 0.15, p.y);
        fern += stem * stem_range * 0.5;
        
        // Left leaflet
        vec2 lp = p;
        float leaf_y = 0.1 + float(iter) * 0.12;
        lp -= vec2(-0.03 - float(iter) * 0.02, leaf_y);
        float la = 0.5;
        vec2 rp = vec2(lp.x * cos(la) - lp.y * sin(la), lp.x * sin(la) + lp.y * cos(la));
        float leaf_l = smoothstep(0.015 * scale, 0.01 * scale, abs(rp.x)) * step(0.0, rp.y) * smoothstep(0.06 * scale, 0.04 * scale, rp.y);
        fern += leaf_l;
        
        // Right leaflet
        vec2 rlp = p;
        rlp -= vec2(0.03 + float(iter) * 0.02, leaf_y);
        float ra = -0.5;
        vec2 rrp = vec2(rlp.x * cos(ra) - rlp.y * sin(ra), rlp.x * sin(ra) + rlp.y * cos(ra));
        float leaf_r = smoothstep(0.015 * scale, 0.01 * scale, abs(rrp.x)) * step(0.0, rrp.y) * smoothstep(0.06 * scale, 0.04 * scale, rrp.y);
        fern += leaf_r;
        
        scale *= 0.7;
    }
    
    fern = min(fern, 1.0);
    
    vec3 bg = vec3(0.03, 0.04, 0.02);
    vec3 leaf_col = vec3(0.15, 0.55, 0.15);
    vec3 stem_col = vec3(0.1, 0.35, 0.1);
    
    vec3 col = bg + fern * mix(stem_col, leaf_col, 0.5);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
