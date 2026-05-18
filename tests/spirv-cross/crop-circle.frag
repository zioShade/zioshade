#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test crop circle pattern (concentric rings in field)
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Wheat field background with rows
    float rows = smoothstep(0.008, 0.0, abs(fract(uv.y * 20.0) - 0.5));
    vec3 wheat = mix(vec3(0.7, 0.65, 0.3), vec3(0.6, 0.55, 0.25), rows);
    
    // Crop circle: multiple concentric flattened rings
    float pattern = 0.0;
    
    // Outer ring
    float ring1 = smoothstep(0.38, 0.36, r) * (1.0 - smoothstep(0.30, 0.28, r));
    
    // Inner ring with segments
    float ring2_base = smoothstep(0.25, 0.23, r) * (1.0 - smoothstep(0.18, 0.16, r));
    float segments = step(0.5, sin(a * 6.0));
    
    // Center circle
    float center = smoothstep(0.08, 0.06, r);
    
    // Connecting paths (radial lines between rings)
    float paths = 0.0;
    for (int i = 0; i < 6; i++) {
        float path_a = float(i) * 1.0472;
        float diff = abs(a - path_a);
        diff = min(diff, 6.2832 - diff);
        paths += smoothstep(0.04, 0.02, diff) * step(0.06, r) * smoothstep(0.4, 0.35, r);
    }
    
    // Flattened wheat (lighter color, direction change)
    float flattened = max(max(ring1, ring2_base * segments), max(center, min(paths, 1.0)));
    
    vec3 flat_wheat = vec3(0.8, 0.75, 0.4);
    vec3 col = mix(wheat, flat_wheat, flattened);
    
    // Trampline (darker line through field)
    float trampline = smoothstep(0.01, 0.0, abs(uv.x - 0.5)) * (1.0 - flattened);
    col = mix(col, vec3(0.35, 0.3, 0.15), trampline * 0.5);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
