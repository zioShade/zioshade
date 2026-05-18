#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test ferris wheel pattern
void main() {
    vec2 p = uv - vec2(0.5, 0.45);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sky
    vec3 col = mix(vec3(0.6, 0.7, 0.9), vec3(0.2, 0.2, 0.4), uv.y);
    
    // Ground
    float ground = smoothstep(0.45, 0.43, uv.y);
    col = mix(col, vec3(0.2, 0.35, 0.15), ground);
    
    // Wheel rim
    float rim = smoothstep(0.005, 0.003, abs(r - 0.3));
    col += rim * vec3(0.6, 0.6, 0.65);
    
    // Inner rim
    float inner_rim = smoothstep(0.003, 0.001, abs(r - 0.05));
    col += inner_rim * vec3(0.5, 0.5, 0.55);
    
    // Spokes
    float spokes = 0.0;
    for (int i = 0; i < 12; i++) {
        float spoke_a = float(i) * 0.5236;
        float diff = abs(a - spoke_a);
        diff = min(diff, 6.2832 - diff);
        spokes += smoothstep(0.02, 0.008, diff) * step(0.05, r) * smoothstep(0.31, 0.29, r);
    }
    col += min(spokes, 1.0) * vec3(0.5, 0.5, 0.55);
    
    // Gondolas (circles at rim)
    for (int i = 0; i < 12; i++) {
        float ga = float(i) * 0.5236;
        vec2 gp = vec2(cos(ga), sin(ga)) * 0.3;
        float gd = length(p - gp);
        float gondola = smoothstep(0.025, 0.02, gd);
        
        // Colorful gondolas
        float t = float(i) / 12.0;
        vec3 gondola_col;
        if (t < 0.2) gondola_col = vec3(0.9, 0.2, 0.2);
        else if (t < 0.4) gondola_col = vec3(0.2, 0.6, 0.9);
        else if (t < 0.6) gondola_col = vec3(0.9, 0.8, 0.1);
        else if (t < 0.8) gondola_col = vec3(0.2, 0.8, 0.3);
        else gondola_col = vec3(0.8, 0.3, 0.8);
        
        col += gondola * gondola_col;
    }
    
    // Support structure (A-frame)
    float support_l = smoothstep(0.008, 0.003, abs(uv.x - (0.5 - (uv.y - 0.05) * 0.5)));
    float support_r = smoothstep(0.008, 0.003, abs(uv.x - (0.5 + (uv.y - 0.05) * 0.5)));
    float support_mask = step(0.05, uv.y) * smoothstep(0.46, 0.44, uv.y);
    col += (support_l + support_r) * support_mask * vec3(0.5, 0.5, 0.55);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
