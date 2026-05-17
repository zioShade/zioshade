#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test float bits conversion pattern
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Use frexp-like decomposition manually
    float exponent = floor(log2(abs(x) + 0.001));
    float mantissa = x / pow(2.0, exponent) - 1.0;
    
    float r = clamp(mantissa + 0.5, 0.0, 1.0);
    float g = clamp((exponent + 5.0) / 10.0, 0.0, 1.0);
    float b = y;
    
    fragColor = vec4(r, g, b, 1.0);
}
