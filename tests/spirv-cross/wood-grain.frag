#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test generating procedural wood grain
void main() {
    vec2 p = uv * 6.0;
    float grain = sin(p.y * 20.0 + sin(p.x * 3.0) * 2.0);
    grain = grain * 0.5 + 0.5;
    
    // Ring pattern
    float r = length(uv - 0.5);
    float ring = sin(r * 30.0) * 0.1;
    
    // Color
    vec3 dark = vec3(0.4, 0.25, 0.1);
    vec3 light = vec3(0.7, 0.5, 0.3);
    vec3 col = mix(dark, light, grain + ring);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
