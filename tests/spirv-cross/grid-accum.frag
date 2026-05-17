#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested loops with accumulation
void main() {
    float total = 0.0;
    
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        for (int j = 0; j < 5; j++) {
            float fj = float(j);
            vec2 center = vec2(fi + 0.5, fj + 0.5) / 5.0;
            float d = length(uv - center);
            total += exp(-d * 20.0) * 0.2;
        }
    }
    
    total = min(total, 1.0);
    vec3 col = vec3(total, total * 0.6, total * 0.3);
    fragColor = vec4(col, 1.0);
}
