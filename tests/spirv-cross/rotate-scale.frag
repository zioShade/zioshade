#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test matrix-vector multiplication patterns
void main() {
    // 2D rotation matrix
    float angle = uv.x * 3.14;
    float c = cos(angle);
    float s = sin(angle);
    
    vec2 p = uv * 2.0 - 1.0;
    vec2 rotated = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    
    // Apply scale
    float scale = 1.0 + uv.y;
    vec2 scaled = rotated * scale;
    
    // Back to 0-1 range
    vec2 result = scaled * 0.5 + 0.5;
    
    fragColor = vec4(clamp(result, 0.0, 1.0), 0.0, 1.0);
}
