#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 6-fold symmetric snowflake
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // 6-fold symmetry: fold angle into 60-degree sector
    float sector = 1.0472; // 60 degrees
    float folded = mod(a, sector);
    folded = min(folded, sector - folded);
    
    // Branch pattern within sector
    float branch = 0.0;
    float scale = 1.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float branch_r = 0.1 + fi * 0.08;
        float branch_width = 0.015 - fi * 0.002;
        float d = abs(folded - 0.0) * r;
        branch += smoothstep(branch_width, branch_width - 0.005, d) * step(branch_r, r) * smoothstep(0.45, 0.4, r);
        
        // Side branches
        float side_angle = 0.3;
        float side_d = abs(folded - side_angle) * r;
        float side_r = branch_r + 0.04;
        branch += smoothstep(0.01, 0.005, side_d) * step(side_r, r) * smoothstep(side_r + 0.1, side_r + 0.08, r);
    }
    
    // Center hex
    float hex = smoothstep(0.03, 0.025, r);
    
    vec3 col = vec3(0.02, 0.03, 0.08);
    col += branch * vec3(0.7, 0.85, 1.0);
    col += hex * vec3(0.9, 0.95, 1.0);
    
    // Sparkle
    float sparkle = step(0.999, fract(sin(dot(floor(uv * 400.0), vec2(12.9, 78.2))) * 43758.5));
    col += sparkle * vec3(0.5, 0.7, 1.0) * smoothstep(0.5, 0.2, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
