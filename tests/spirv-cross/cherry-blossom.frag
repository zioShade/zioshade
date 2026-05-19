#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test cherry blossom (sakura) with petals and branches
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    // Sky blue background
    vec3 col = mix(vec3(0.75, 0.85, 0.95), vec3(0.6, 0.75, 0.9), uv.y);
    
    // Branches (dark brown curves)
    float branches = 0.0;
    // Main branch (diagonal)
    vec2 bp1 = uv - vec2(-0.1, 0.3);
    float bdist1 = abs(bp1.x * 0.5 - bp1.y) / 0.707;
    branches += smoothstep(0.012, 0.008, bdist1) * step(0.0, uv.x) * step(uv.x, 0.7) * step(0.2, uv.y) * step(uv.y, 0.8);
    
    // Secondary branch
    vec2 bp2 = uv - vec2(0.4, 0.15);
    float bdist2 = abs(bp2.x + bp2.y * 0.5) / 1.118;
    branches += smoothstep(0.008, 0.005, bdist2) * step(0.25, uv.x) * step(uv.y, 0.75);
    
    // Sub-branch
    vec2 bp3 = uv - vec2(0.15, 0.55);
    float bdist3 = abs(bp3.x - bp3.y * 0.3) / 1.044;
    branches += smoothstep(0.006, 0.003, bdist3) * step(0.1, uv.x) * step(uv.x, 0.5) * step(0.4, uv.y);
    
    vec3 bark = vec3(0.35, 0.22, 0.15);
    col = mix(col, bark, min(branches, 1.0));
    
    // Cherry blossom petals (5-petal flowers scattered along branches)
    for (int i = 0; i < 14; i++) {
        float fi = float(i);
        float fx = fract(sin(fi * 7.3) * 43.7) * 0.7 + 0.1;
        float fy = fract(cos(fi * 11.1) * 37.9) * 0.5 + 0.25;
        
        vec2 fp = uv - vec2(fx, fy);
        float fr = length(fp);
        float fa = atan(fp.y, fp.x);
        
        // 5 petals (rounded bumps)
        float petal = 0.0;
        for (int j = 0; j < 5; j++) {
            float fj = float(j);
            float pa = fj * 1.2566 - 1.5708; // 2*PI/5
            vec2 petal_dir = vec2(cos(pa), sin(pa));
            float proj = dot(fp, petal_dir);
            float perp = abs(dot(fp, vec2(-petal_dir.y, petal_dir.x)));
            float petal_shape = smoothstep(0.03, 0.015, perp) * step(0.0, proj) * smoothstep(0.04, 0.035, proj);
            petal += petal_shape;
        }
        
        // Color: pink to white with depth
        float h = hash(vec2(fi, 0.0));
        vec3 pink = mix(vec3(1.0, 0.7, 0.8), vec3(1.0, 0.85, 0.9), h);
        col = mix(col, pink, min(petal, 1.0));
        
        // Center (yellow dot)
        float center = smoothstep(0.006, 0.003, fr);
        col = mix(col, vec3(1.0, 0.9, 0.3), center);
    }
    
    // Falling petals (simplified)
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float px = fract(sin(fi * 3.7 + 0.5) * 23.1);
        float py = fract(cos(fi * 5.3 + 0.2) * 17.9);
        float pd = length((uv - vec2(px, py)) * vec2(1.5, 1.0));
        float petal = smoothstep(0.012, 0.008, pd);
        col = mix(col, vec3(1.0, 0.75, 0.85), petal);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
