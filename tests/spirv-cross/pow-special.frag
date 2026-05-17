#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test power function with special cases
void main() {
    float x = uv.x * 4.0;
    float y = uv.y;
    
    // Various pow cases
    float p1 = pow(x, 2.0);          // x^2
    float p2 = pow(x, 0.5);          // sqrt(x)
    float p3 = pow(max(x, 0.001), -1.0); // 1/x
    float p4 = pow(y, 3.0);          // y^3
    
    float r = clamp(p1 * 0.1, 0.0, 1.0);
    float g = clamp(p2 * 0.5, 0.0, 1.0);
    float b = clamp(p4, 0.0, 1.0);
    
    fragColor = vec4(r, g, b, 1.0);
}
