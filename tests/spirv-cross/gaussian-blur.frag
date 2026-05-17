#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test integer for loop with float accumulation
void main() {
    float sum = 0.0;
    
    for (int i = -5; i <= 5; i++) {
        float fi = float(i);
        float weight = exp(-fi * fi * 0.5);
        float val = sin(uv.x * fi + uv.y * fi * 0.5);
        sum += val * weight;
    }
    
    sum /= 5.0;
    
    vec3 col = vec3(sum * 0.5 + 0.5);
    col *= vec3(0.9, 0.7, 1.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
