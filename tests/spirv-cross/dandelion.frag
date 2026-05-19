#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dandelion seed head pattern
void main() {
    vec2 p = uv - vec2(0.5, 0.4);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Stem
    float stem = smoothstep(0.01, 0.005, abs(uv.x - 0.5)) * step(uv.y, 0.42) * step(0.05, uv.y);
    
    // Seed head sphere (many radiating seeds)
    vec3 col = vec3(0.5, 0.7, 0.9); // sky
    
    // Seeds radiating from center
    float seeds = 0.0;
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float seed_a = fi * 0.31416 + sin(fi * 1.7) * 0.3;
        vec2 dir = vec2(cos(seed_a), sin(seed_a));
        
        // Seed filament: thin line from center outward
        float proj = dot(p, dir);
        float perp = abs(dot(p, vec2(-dir.y, dir.x)));
        float filament = smoothstep(0.003, 0.001, perp) * step(0.0, proj) * smoothstep(0.35, 0.33, proj);
        
        // Seed tuft at end (tiny circle)
        vec2 tip = dir * (0.25 + fi * 0.005);
        float tuft = smoothstep(0.015, 0.01, length(p - tip));
        
        seeds += filament * 0.5 + tuft;
    }
    
    // Center sphere
    float center = smoothstep(0.06, 0.04, r);
    
    // Flying seeds
    float fly1 = smoothstep(0.008, 0.004, length(uv - vec2(0.75, 0.7)));
    float fly2 = smoothstep(0.006, 0.003, length(uv - vec2(0.82, 0.55)));
    float fly3 = smoothstep(0.007, 0.003, length(uv - vec2(0.65, 0.8)));
    
    vec3 seed_col = vec3(0.9, 0.9, 0.85);
    vec3 stem_col = vec3(0.3, 0.5, 0.2);
    
    col = mix(col, seed_col * 0.7, min(seeds, 1.0));
    col = mix(col, seed_col, center);
    col = mix(col, stem_col, stem);
    col += fly1 * seed_col + fly2 * seed_col + fly3 * seed_col;
    
    // Ground
    float ground = smoothstep(0.08, 0.05, uv.y);
    col = mix(col, vec3(0.3, 0.45, 0.2), ground);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
