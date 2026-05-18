#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test radiolaria (microscopic sea creature) pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Radial spines
    float spines = 16.0;
    float spine_angle = 6.28318 / spines;
    float nearest_spine = abs(mod(a + spine_angle * 0.5, spine_angle) - spine_angle * 0.5);
    float spine = smoothstep(0.04, 0.01, nearest_spine) * step(0.08, r) * smoothstep(0.48, 0.45, r);
    
    // Concentric mesh rings
    float mesh = 0.0;
    for (int i = 1; i <= 6; i++) {
        float cr = float(i) * 0.07;
        mesh += smoothstep(0.005, 0.0, abs(r - cr)) * smoothstep(0.45, 0.1, r);
    }
    
    // Central capsule
    float capsule = smoothstep(0.08, 0.06, r);
    float inner_ring = smoothstep(0.065, 0.055, r) * (1.0 - smoothstep(0.05, 0.04, r));
    
    // Pores between spines
    float pore_r = 0.15 + 0.05 * sin(a * spines);
    float pore = smoothstep(0.02, 0.01, abs(r - pore_r)) * smoothstep(0.04, 0.0, nearest_spine - 0.1);
    
    vec3 col = vec3(0.02, 0.03, 0.06);
    col += spine * vec3(0.5, 0.7, 0.8);
    col += mesh * vec3(0.3, 0.5, 0.6);
    col += capsule * vec3(0.6, 0.4, 0.3);
    col += inner_ring * vec3(0.8, 0.6, 0.4);
    col += pore * vec3(0.4, 0.6, 0.5);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
