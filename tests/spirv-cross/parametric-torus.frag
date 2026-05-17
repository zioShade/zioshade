#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Parametric surface evaluation (torus cross-section)
void main() {
    float u = uv.x * 6.28;
    float v = uv.y * 6.28;
    
    float R = 1.0;  // Major radius
    float r = 0.4;  // Minor radius
    
    vec3 p;
    p.x = (R + r * cos(v)) * cos(u);
    p.y = (R + r * cos(v)) * sin(u);
    p.z = r * sin(v);
    
    // Map 3D to color
    vec3 col = p * 0.3 + 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
