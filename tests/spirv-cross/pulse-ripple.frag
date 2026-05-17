#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pulse/ripple pattern with time-like variable
void main() {
    vec2 center = vec2(0.5);
    float d = length(uv - center);
    
    // Concentric rings
    float ring = sin(d * 40.0) * 0.5 + 0.5;
    
    // Expanding wave effect using uv as time proxy
    float wave = sin(d * 20.0 - uv.x * 6.28) * 0.5 + 0.5;
    
    // Fade with distance
    float fade = exp(-d * 3.0);
    
    vec3 col1 = vec3(0.2, 0.4, 0.8) * ring * fade;
    vec3 col2 = vec3(0.8, 0.3, 0.2) * wave * fade;
    
    vec3 col = col1 + col2;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
