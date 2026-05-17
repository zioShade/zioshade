#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Kali set fractal
void main() {
    vec2 p = uv * 3.0 - 1.5;
    float scale = 1.0;
    
    for (int i = 0; i < 12; i++) {
        p = abs(p) / clamp(dot(p, p), 0.1, 1.0) - vec2(0.7, 0.7);
        scale *= 0.95;
    }
    
    float r = length(p);
    float col = clamp(r * scale, 0.0, 1.0);
    
    vec3 color = vec3(col * 0.8, col * 0.3, col);
    fragColor = vec4(color, 1.0);
}
