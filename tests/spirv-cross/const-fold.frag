#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test constant folding edge cases
void main() {
    // These should all fold correctly
    float a = 1.0 + 2.0;      // 3.0
    float b = 4.0 * 0.5;      // 2.0
    float c = 10.0 / 3.0;     // 3.33...
    float d = -(-5.0);         // 5.0
    
    // Runtime values
    float x = uv.x;
    float y = uv.y;
    
    // Mix of constant and runtime
    float r = x * a / 10.0;
    float g = y * b / 5.0;
    float bl = c * 0.3 + d * 0.02;
    
    fragColor = vec4(clamp(vec3(r, g, bl), 0.0, 1.0), 1.0);
}
