#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test checkerboard with multiple scales
void main() {
    // Basic checker
    float c1 = mod(floor(uv.x * 8.0) + floor(uv.y * 8.0), 2.0);
    
    // Small checker
    float c2 = mod(floor(uv.x * 16.0) + floor(uv.y * 16.0), 2.0);
    
    // Diagonal checker
    float c3 = mod(floor((uv.x + uv.y) * 10.0), 2.0);
    
    // Mix
    float mix1 = mix(c1, c2, 0.5);
    float final = mix(mix1, c3, 0.3);
    
    vec3 col = vec3(final * 0.7 + 0.15);
    col *= vec3(1.0, 0.9, 0.8);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
