#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mat2 operations
void main() {
    float angle = uv.x * 6.28318;
    float c = cos(angle);
    float s = sin(angle);
    
    mat2 rot = mat2(c, -s, s, c);
    vec2 p = uv * 2.0 - 1.0;
    vec2 rotated = rot * p;
    
    // Scale matrix
    mat2 scale = mat2(2.0, 0.0, 0.0, 0.5);
    vec2 scaled = scale * rotated;
    
    float d = length(scaled);
    float col = smoothstep(1.0, 0.9, d);
    
    fragColor = vec4(col * rotated.x + 0.5, col * rotated.y + 0.5, col, 1.0);
}
