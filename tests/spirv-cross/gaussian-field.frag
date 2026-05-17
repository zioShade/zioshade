#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test large-scale loop accumulation
void main() {
    float sum = 0.0;
    float w = 1.0;
    float total_w = 0.0;
    
    for (int i = 0; i < 16; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(fi * 0.7) * 0.3 + 0.5,
            cos(fi * 0.5) * 0.3 + 0.5
        );
        float d = length(uv - center);
        float weight = exp(-d * d * 20.0);
        sum += weight * (fi / 16.0);
        total_w += weight;
    }
    
    sum /= (total_w + 0.001);
    
    vec3 col = vec3(sum, sum * 0.6, 1.0 - sum);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
