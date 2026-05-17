#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gl_FrontFacing (via alternate approach with varying)
void main() {
    // Color pattern that should be consistent
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    
    // Concentric rings
    float ring = sin(r * 20.0) * 0.5 + 0.5;
    
    // Angular color shift
    float angle = atan(p.y, p.x);
    vec3 col = ring * vec3(
        sin(angle) * 0.5 + 0.5,
        sin(angle + 2.094) * 0.5 + 0.5,
        sin(angle + 4.189) * 0.5 + 0.5
    );
    
    col *= smoothstep(1.0, 0.2, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
