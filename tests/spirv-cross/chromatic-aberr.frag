#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test chromatic aberration
void main() {
    vec2 p = uv - 0.5;
    float d = length(p);
    float a = atan(p.y, p.x);
    
    float aberration = d * 0.1;
    
    // Separate channels with offset
    float r = sin(a * 6.0 + d * 20.0 - aberration) * 0.5 + 0.5;
    float g = sin(a * 6.0 + d * 20.0) * 0.5 + 0.5;
    float b = sin(a * 6.0 + d * 20.0 + aberration) * 0.5 + 0.5;
    
    vec3 col = vec3(r, g, b);
    col *= smoothstep(0.6, 0.1, d);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
