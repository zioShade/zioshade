#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gear/mechanical pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Gear teeth
    float teeth = 12.0;
    float tooth_angle = 6.28318 / teeth;
    float tooth = step(0.5, fract(a / tooth_angle));
    
    float inner_r = 0.15;
    float outer_r = mix(0.2, 0.25, tooth);
    
    float gear_body = smoothstep(outer_r, outer_r - 0.01, r) * (1.0 - smoothstep(inner_r, inner_r + 0.01, r));
    float gear_center = smoothstep(0.05, 0.04, r);
    float spoke = smoothstep(0.02, 0.01, min(abs(p.x), abs(p.y))) * step(inner_r, r) * step(r, outer_r);
    
    float gear = max(max(gear_body, gear_center), spoke);
    
    vec3 metal = vec3(0.6, 0.6, 0.65);
    vec3 bg = vec3(0.1);
    
    vec3 col = mix(bg, metal, gear);
    fragColor = vec4(col, 1.0);
}
