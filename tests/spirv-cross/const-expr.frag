#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test constant folding with runtime values
void main() {
    // Constants
    const float PI = 3.14159265;
    const float TWO_PI = 6.28318530;
    const float HALF_PI = 1.57079632;
    
    float angle = uv.x * TWO_PI;
    float r = uv.y;
    
    // Use constants in expressions
    float x = cos(angle) * r;
    float y = sin(angle) * r;
    
    // Check quadrant
    float quadrant = floor(angle / HALF_PI);
    float q_frac = fract(angle / HALF_PI);
    
    vec3 col = vec3(x * 0.5 + 0.5, y * 0.5 + 0.5, q_frac);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
