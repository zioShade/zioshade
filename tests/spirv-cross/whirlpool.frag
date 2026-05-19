#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test whirlpool / vortex pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Spiral arms (logarithmic spiral)
    float spiral = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float offset = fi * 2.0944; // 2*PI/3
        float spiral_a = a - offset - log(r + 0.01) * 2.5;
        float arm = sin(spiral_a * 3.0) * 0.5 + 0.5;
        arm = smoothstep(0.4, 0.6, arm);
        spiral += arm;
    }
    spiral = min(spiral, 1.0);
    
    // Center pull (brighter toward center)
    float center_glow = exp(-r * 8.0);
    
    // Color: deep blue water
    vec3 deep = vec3(0.02, 0.05, 0.15);
    vec3 mid = vec3(0.05, 0.15, 0.35);
    vec3 light = vec3(0.1, 0.3, 0.5);
    vec3 foam = vec3(0.6, 0.75, 0.85);
    
    vec3 col = deep;
    col = mix(col, mid, spiral * (1.0 - center_glow));
    col = mix(col, light, spiral * center_glow);
    col = mix(col, foam, center_glow * 0.5);
    
    // Concentric ripples
    float ripple = sin(r * 40.0) * 0.5 + 0.5;
    ripple *= exp(-r * 4.0) * 0.15;
    col += ripple * vec3(0.3, 0.5, 0.7);
    
    // Outer foam ring
    float foam_ring = smoothstep(0.4, 0.38, r) * (1.0 - smoothstep(0.35, 0.33, r));
    col += foam_ring * vec3(0.4, 0.55, 0.65);
    
    // Dark void at center
    float void_center = smoothstep(0.03, 0.01, r);
    col = mix(col, vec3(0.0, 0.01, 0.03), void_center);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
