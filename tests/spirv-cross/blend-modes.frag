#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pow-based blending modes
void main() {
    float a = uv.x;
    float b = uv.y;
    
    // Screen blend: 1 - (1-a)(1-b)
    float screen = 1.0 - (1.0 - a) * (1.0 - b);
    
    // Overlay blend
    float overlay = a < 0.5 ? (2.0 * a * b) : (1.0 - 2.0 * (1.0 - a) * (1.0 - b));
    
    // Soft light
    float soft = (1.0 - 2.0 * b) * a * a + 2.0 * b * a;
    
    vec3 col = vec3(screen, overlay, soft);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
