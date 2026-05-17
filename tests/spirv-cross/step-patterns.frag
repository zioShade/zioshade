#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test step function with varying step sizes
void main() {
    float x = uv.x * 10.0;
    float y = uv.y * 10.0;
    
    // Different step sizes
    float s1 = floor(x) / 10.0;
    float s2 = floor(y * 0.5) / 5.0;
    float s3 = floor(x * 0.3 + y * 0.3) / 3.0;
    
    // Staircase pattern
    float stair = floor(x + y) / 20.0;
    
    vec3 col = vec3(s1, s2, s3) + stair * 0.5;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
