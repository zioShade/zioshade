#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test inverse hyperbolic functions
void main() {
    float x = uv.x * 2.0 - 0.5;
    
    float asinh_val = log(x + sqrt(x * x + 1.0));
    float acosh_val = log(x + sqrt(x * x - 1.0 + 0.01));
    float atanh_val = 0.5 * log((1.0 + x) / (1.0 - x + 0.01));
    
    float r = clamp(asinh_val * 0.5 + 0.5, 0.0, 1.0);
    float g = clamp(acosh_val * 0.3, 0.0, 1.0);
    float b = clamp(atanh_val * 0.3 + 0.5, 0.0, 1.0);
    
    fragColor = vec4(r, g, b, 1.0);
}
