#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test windmill / mechanical gear pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Main gear
    float teeth = 12.0;
    float tooth_freq = a * teeth;
    float tooth = sin(tooth_freq) * 0.5 + 0.5;
    float outer_r = mix(0.35, 0.38, tooth);
    float gear = smoothstep(outer_r, outer_r - 0.01, r);
    float inner = smoothstep(0.22, 0.21, r);
    float gear_body = gear * (1.0 - inner);
    
    // Spokes
    float spokes = 0.0;
    for (int i = 0; i < 4; i++) {
        float spoke_a = float(i) * 1.5708;
        float diff = abs(a - spoke_a);
        diff = min(diff, 6.2832 - diff);
        spokes += smoothstep(0.06, 0.03, diff) * step(0.06, r) * smoothstep(0.22, 0.2, r);
    }
    
    // Center hub
    float hub = smoothstep(0.07, 0.06, r);
    float hub_hole = smoothstep(0.03, 0.025, r);
    
    // Second smaller gear (meshing)
    vec2 p2 = p - vec2(0.55, 0.15);
    float r2 = length(p2);
    float a2 = atan(p2.y, p2.x);
    float teeth2 = 8.0;
    float tooth2 = sin(a2 * teeth2 + 0.3) * 0.5 + 0.5;
    float outer_r2 = mix(0.18, 0.2, tooth2);
    float gear2 = smoothstep(outer_r2, outer_r2 - 0.008, r2);
    float hub2 = smoothstep(0.04, 0.03, r2);
    
    vec3 metal = vec3(0.55, 0.55, 0.6);
    vec3 dark_metal = vec3(0.35, 0.35, 0.4);
    vec3 hub_col = vec3(0.4, 0.35, 0.3);
    
    vec3 col = vec3(0.12, 0.15, 0.2);
    col = mix(col, metal, gear_body);
    col = mix(col, dark_metal, min(spokes, 1.0));
    col = mix(col, hub_col, hub);
    col = mix(col, vec3(0.1), hub_hole);
    col = mix(col, metal * 0.9, gear2);
    col = mix(col, hub_col, hub2);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
