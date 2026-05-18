#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test moire spiral pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Two interleaved spirals
    float spiral1 = sin(a * 8.0 + r * 30.0);
    float spiral2 = sin(a * 8.0 - r * 30.0);
    
    float pattern = spiral1 * spiral2;
    pattern = pattern * 0.5 + 0.5;
    
    // Central glow
    float glow = exp(-r * r * 8.0) * 0.5;
    
    vec3 col = pattern * vec3(0.4, 0.6, 0.9);
    col += glow * vec3(0.8, 0.9, 1.0);
    col *= smoothstep(0.55, 0.2, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
