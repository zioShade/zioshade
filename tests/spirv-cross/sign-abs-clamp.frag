#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sign, abs, and clamping
void main() {
    float x = uv.x * 2.0 - 1.0;
    float y = uv.y * 2.0 - 1.0;
    
    float s1 = sign(x);
    float a1 = abs(x);
    float c1 = clamp(x, -0.5, 0.5);
    
    float s2 = sign(y);
    float a2 = abs(y);
    float c2 = clamp(y, -0.5, 0.5);
    
    float r = s1 * a2 * 0.5 + 0.5;
    float g = a1 * c2 * 0.5 + 0.5;
    float b = c1 * s2 * 0.5 + 0.5;
    
    fragColor = vec4(r, g, b, 1.0);
}
