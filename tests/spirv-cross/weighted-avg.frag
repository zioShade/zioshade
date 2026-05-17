#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test weighted average with varying weights
void main() {
    float sum = 0.0;
    float wsum = 0.0;
    
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float weight = 1.0 / (fi + 1.0);
        float value = sin(uv.x * fi * 2.0 + fi) * cos(uv.y * fi * 1.5);
        sum += value * weight;
        wsum += weight;
    }
    
    float avg = sum / wsum;
    vec3 col = vec3(avg * 0.5 + 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
