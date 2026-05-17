#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple discard paths
void main() {
    // Discard based on distance from center
    float d = length(uv - 0.5);
    
    if (d > 0.45 && d < 0.5) discard;
    if (d > 0.25 && d < 0.28) discard;
    
    // Ring pattern
    float ring = sin(d * 40.0) * 0.5 + 0.5;
    vec3 col = vec3(ring, ring * 0.5, 1.0 - ring);
    
    fragColor = vec4(col, 1.0);
}
