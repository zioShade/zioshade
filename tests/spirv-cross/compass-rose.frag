#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test compass rose pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // 8-point star
    float star = 0.0;
    for (int i = 0; i < 8; i++) {
        float angle = float(i) * 0.7854; // 45 degrees
        float diff = abs(a - angle);
        diff = min(diff, 6.2832 - diff);
        float point = smoothstep(0.15, 0.1, diff) * smoothstep(0.4, 0.1, r);
        star = max(star, point);
    }
    
    // Inner circle
    float inner = smoothstep(0.06, 0.05, r);
    
    // Cardinal direction markers
    float n = smoothstep(0.005, 0.0, abs(p.x)) * step(0.05, r) * step(r, 0.35);
    float e = smoothstep(0.005, 0.0, abs(p.y)) * step(0.05, r) * step(r, 0.35);
    float cross = max(n, e);
    
    // Outer ring
    float ring = smoothstep(0.38, 0.37, r) * (1.0 - smoothstep(0.35, 0.36, r));
    
    vec3 col = vec3(0.05);
    col += star * vec3(0.8, 0.6, 0.2);
    col += inner * vec3(0.9, 0.3, 0.2);
    col += cross * vec3(0.4, 0.4, 0.5);
    col += ring * vec3(0.6, 0.6, 0.7);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
