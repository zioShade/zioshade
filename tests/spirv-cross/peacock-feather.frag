#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test peacock feather eye pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Concentric rings with color shift
    float rings = sin(r * 30.0) * 0.5 + 0.5;
    
    // Radial feather barbs
    float barbs = sin(a * 20.0) * 0.5 + 0.5;
    barbs = pow(barbs, 8.0);
    
    // Eye center
    float eye = smoothstep(0.08, 0.05, r);
    
    // Iris ring
    float iris = smoothstep(0.12, 0.1, r) * (1.0 - smoothstep(0.08, 0.07, r));
    
    vec3 col = vec3(0.02, 0.05, 0.02);
    col += rings * vec3(0.1, 0.3, 0.15) * smoothstep(0.4, 0.1, r);
    col += barbs * vec3(0.05, 0.15, 0.1) * smoothstep(0.45, 0.15, r);
    col += eye * vec3(0.1, 0.1, 0.15);
    col += iris * vec3(0.2, 0.6, 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
