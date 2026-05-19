#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test interlocking gear mechanism
void main() {
    vec3 col = vec3(0.08, 0.08, 0.12);
    
    // Gear 1 (large, center-left)
    vec2 p1 = uv - vec2(0.35, 0.5);
    float r1 = length(p1);
    float a1 = atan(p1.y, p1.x);
    float teeth1 = 16.0;
    float tooth1 = sin(a1 * teeth1) * 0.5 + 0.5;
    float outer1 = mix(0.22, 0.25, tooth1);
    float gear1 = smoothstep(outer1, outer1 - 0.005, r1);
    float inner1 = smoothstep(0.16, 0.15, r1);
    float hub1 = smoothstep(0.05, 0.04, r1);
    float hole1 = smoothstep(0.02, 0.015, r1);
    
    // Spokes gear 1
    float spokes1 = 0.0;
    for (int i = 0; i < 6; i++) {
        float sa = float(i) * 1.0472;
        float diff = abs(a1 - sa);
        diff = min(diff, 6.2832 - diff);
        spokes1 += smoothstep(0.08, 0.03, diff) * step(0.06, r1) * smoothstep(0.17, 0.15, r1);
    }
    
    vec3 metal1 = vec3(0.6, 0.58, 0.55);
    col = mix(col, metal1, gear1 * (1.0 - inner1));
    col = mix(col, metal1 * 0.8, min(spokes1, 1.0) * inner1);
    col = mix(col, metal1 * 0.9, hub1);
    col = mix(col, vec3(0.05), hole1);
    
    // Gear 2 (small, center-right, meshes with gear 1)
    vec2 p2 = uv - vec2(0.68, 0.5);
    float r2 = length(p2);
    float a2 = atan(p2.y, p2.x);
    float teeth2 = 10.0;
    float tooth2 = sin(a2 * teeth2 + 0.3) * 0.5 + 0.5;
    float outer2 = mix(0.14, 0.16, tooth2);
    float gear2 = smoothstep(outer2, outer2 - 0.005, r2);
    float hub2 = smoothstep(0.035, 0.03, r2);
    float hole2 = smoothstep(0.015, 0.01, r2);
    
    col = mix(col, metal1 * 0.9, gear2);
    col = mix(col, metal1 * 0.85, hub2);
    col = mix(col, vec3(0.05), hole2);
    
    // Axle connecting the two gears
    float axle = smoothstep(0.006, 0.003, abs(uv.y - 0.5)) * step(0.35, uv.x) * step(uv.x, 0.68);
    col += axle * vec3(0.4, 0.38, 0.35);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
