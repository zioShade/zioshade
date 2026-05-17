#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sequential assignment and side effects
void main() {
    float a = uv.x;
    float b = uv.y;
    float c = 0.0;
    
    c = a + b;
    a = c * 2.0;
    b = a - c;
    c = c + a * b;
    
    // Chained assignments
    float d = c;
    d += d;
    d *= 0.25;
    
    fragColor = vec4(clamp(vec3(a, b, d), 0.0, 1.0), 1.0);
}
