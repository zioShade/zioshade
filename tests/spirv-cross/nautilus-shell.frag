#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nautilus shell spiral
void main() {
    vec2 p = uv - vec2(0.6, 0.5);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Golden spiral: r = a * phi^(theta/b)
    float golden = 1.618;
    float spiral_r = 0.01 * pow(golden, a * 2.0);
    
    // Shell thickness
    float shell = smoothstep(0.012, 0.008, abs(r - spiral_r));
    
    // Chamber walls (radial lines at intervals)
    float chamber_angle = 0.5236; // ~30 degrees
    float chamber = 0.0;
    for (int i = 0; i < 12; i++) {
        float ca = float(i) * chamber_angle;
        float diff = abs(a - ca);
        diff = min(diff, 6.2832 - diff);
        float inner_r = 0.01 * pow(golden, (ca - 0.5) * 2.0);
        float outer_r = 0.01 * pow(golden, (ca + 0.5) * 2.0);
        float in_range = step(inner_r, r) * step(r, outer_r);
        chamber += smoothstep(0.03, 0.01, diff) * in_range;
    }
    
    // Shell coloring (iridescent nacre)
    float t = r * 8.0;
    vec3 nacre = mix(vec3(0.8, 0.7, 0.6), vec3(0.9, 0.85, 0.95), fract(t));
    
    vec3 col = vec3(0.03, 0.05, 0.1);
    col += shell * nacre;
    col += chamber * vec3(0.5, 0.45, 0.4);
    
    // Center pearl
    float pearl = smoothstep(0.03, 0.02, r);
    col += pearl * vec3(0.95, 0.92, 0.88);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
