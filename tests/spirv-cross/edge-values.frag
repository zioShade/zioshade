#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test edge cases: very small and very large values
void main() {
    float eps = 1e-6;
    float big = 1e6;
    
    float a = uv.x * big;
    float b = uv.y + eps;
    
    // Test that operations don't break
    float r = clamp(a / big, 0.0, 1.0);
    float g = clamp(log(b) / log(2.0), 0.0, 1.0);
    float bl = clamp(exp(-a * 0.001), 0.0, 1.0);
    
    fragColor = vec4(r, g, bl, 1.0);
}
