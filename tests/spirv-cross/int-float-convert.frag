#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test implicit int→float in complex expressions
void main() {
    int n = int(uv.x * 10.0);
    float f = uv.y;
    
    // Implicit conversion in arithmetic
    float r = float(n) / 10.0;
    float g = f * float(n + 1) / 11.0;
    float b = sin(float(n) * 0.5 + f * 3.0) * 0.5 + 0.5;
    
    fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), b, 1.0);
}
