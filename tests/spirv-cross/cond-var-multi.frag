#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple conditional variable mutations in sequence
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // First conditional: modify x
    if (x > 0.5) {
        x *= 2.0;
    }
    
    // Second conditional: modify y
    if (y > 0.5) {
        y = 1.0 - y;
    }
    
    // Third conditional: modify x again based on y
    if (y < 0.3) {
        x += 0.2;
    }
    
    vec3 col = vec3(fract(x * 5.0), fract(y * 5.0), 0.3);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
