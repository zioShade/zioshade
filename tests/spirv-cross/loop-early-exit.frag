#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex loop with early exit
void main() {
    float sum = 0.0;
    float product = 1.0;
    
    for (int i = 1; i <= 20; i++) {
        float fi = float(i);
        float val = sin(fi * 0.7 + uv.x * 3.0) * cos(fi * 0.5 + uv.y * 2.0);
        sum += val;
        product *= (1.0 + val * 0.1);
        
        if (abs(sum) > 5.0) break;
    }
    
    float r = clamp(sum * 0.1 + 0.5, 0.0, 1.0);
    float g = clamp(product * 0.3, 0.0, 1.0);
    float b = clamp(abs(sum) * 0.15, 0.0, 1.0);
    
    fragColor = vec4(r, g, b, 1.0);
}
