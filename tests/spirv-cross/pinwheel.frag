#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pinwheel / wind spinner pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Background
    vec3 col = vec3(0.95, 0.93, 0.9);
    
    // Pinwheel: 8 triangular blades with alternating colors
    float blade_angle = 0.7854; // PI/4
    float blade_frac = fract(a / blade_angle);
    
    // Blade shape: widening outward
    float blade_width = 0.15 + blade_frac * 0.15;
    float blade = smoothstep(blade_width + 0.005, blade_width, r) * step(0.02, r);
    
    // Alternating colors via sin
    float t = a / blade_angle;
    vec3 c1 = vec3(0.9, 0.2, 0.15);
    vec3 c2 = vec3(0.15, 0.5, 0.9);
    vec3 c3 = vec3(0.95, 0.8, 0.1);
    vec3 c4 = vec3(0.15, 0.75, 0.3);
    
    float w1 = max(0.0, cos(t * 1.5708));
    float w2 = max(0.0, cos((t - 1.0) * 1.5708));
    float w3 = max(0.0, cos((t - 2.0) * 1.5708));
    float w4 = max(0.0, cos((t - 3.0) * 1.5708));
    float w5 = max(0.0, cos((t - 4.0) * 1.5708));
    float w6 = max(0.0, cos((t - 5.0) * 1.5708));
    float w7 = max(0.0, cos((t - 6.0) * 1.5708));
    float w8 = max(0.0, cos((t - 7.0) * 1.5708));
    
    vec3 blade_col = c1 * w1 + c2 * w2 + c3 * w3 + c4 * w4 + c1 * w5 + c2 * w6 + c3 * w7 + c4 * w8;
    
    // Slight shading per blade
    float shade = 0.8 + blade_frac * 0.2;
    blade_col *= shade;
    
    col = mix(col, blade_col, blade);
    
    // Center pin
    float pin = smoothstep(0.025, 0.02, r);
    col = mix(col, vec3(0.3, 0.3, 0.35), pin);
    float pin_hl = exp(-dot(p - vec2(-0.005, 0.005), p - vec2(-0.005, 0.005)) * 800.0);
    col += pin_hl * 0.3;
    
    // Stick
    float stick = smoothstep(0.006, 0.003, abs(uv.x - 0.5)) * step(0.5, uv.y) * smoothstep(0.98, 0.96, uv.y);
    col = mix(col, vec3(0.55, 0.45, 0.35), stick);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
