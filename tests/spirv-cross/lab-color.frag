#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Gradient through Lab-like color space
void main() {
    float l = uv.y;
    float a = (uv.x - 0.5) * 2.0;
    float b = sin(uv.y * 3.14) * (uv.x - 0.5) * 2.0;
    
    // Simplified Lab to RGB
    vec3 col;
    col.r = l + a * 0.5;
    col.g = l - a * 0.25 - b * 0.25;
    col.b = l + b * 0.5;
    
    col = clamp(col, 0.0, 1.0);
    fragColor = vec4(col, 1.0);
}
