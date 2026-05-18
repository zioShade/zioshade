#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Fibonacci / golden spiral pattern
void main() {
    vec2 p = uv - vec2(0.618, 0.5);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Golden ratio
    float phi = 1.618;
    
    // Golden spiral: r = c * phi^(theta / (pi/2))
    float spiral_r = 0.005 * pow(phi, a / 1.5708);
    
    // Multiple spiral arms offset by golden angle
    float golden_angle = 2.39996; // radians
    float spiral1 = smoothstep(0.01, 0.005, abs(r - spiral_r));
    
    float a2 = a + golden_angle;
    float spiral_r2 = 0.005 * pow(phi, a2 / 1.5708);
    float spiral2 = smoothstep(0.01, 0.005, abs(r - spiral_r2));
    
    // Sunflower seed arrangement (Fibonacci)
    float seeds = 0.0;
    for (int i = 0; i < 40; i++) {
        float fi = float(i);
        float seed_a = fi * golden_angle;
        float seed_r = sqrt(fi) * 0.07;
        vec2 seed_pos = vec2(cos(seed_a), sin(seed_a)) * seed_r;
        float d = length(p - seed_pos);
        seeds += smoothstep(0.012, 0.006, d);
    }
    
    // Background: concentric rings for phyllotaxis
    float rings = sin(r * 20.0) * 0.5 + 0.5;
    
    vec3 col = vec3(0.04, 0.03, 0.06);
    col += (spiral1 + spiral2) * vec3(0.5, 0.4, 0.2) * smoothstep(0.5, 0.1, r);
    col += seeds * vec3(0.8, 0.7, 0.3);
    col += rings * vec3(0.1, 0.08, 0.12) * smoothstep(0.5, 0.0, r) * 0.3;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
