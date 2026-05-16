#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Fibonacci spiral approximation
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);
    
    // Golden ratio
    float phi = 1.618033988749;
    
    // Spiral arms based on golden angle
    float golden_angle = 2.39996323;
    float arms = 8.0;
    float spiral = 0.0;
    
    for (int i = 0; i < 8; i++) {
        float a = angle - float(i) * golden_angle;
        float d = r - pow(phi, float(i) * 0.3) * 0.15;
        spiral += smoothstep(0.02, 0.0, abs(d)) * step(0.0, r);
    }
    
    spiral = min(spiral, 1.0);
    
    vec3 col = vec3(0.05);
    col += vec3(0.9, 0.7, 0.2) * spiral;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
