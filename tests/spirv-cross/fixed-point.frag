#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test do-while with complex condition
void main() {
    float x = uv.x;
    float prev = x;
    float curr = x * 0.5;
    int iters = 0;
    
    // Fixed-point iteration
    do {
        prev = curr;
        curr = (curr + x / (curr + 0.001)) * 0.5;
        iters++;
    } while (abs(curr - prev) > 0.001 && iters < 10);
    
    float r = curr;
    float g = float(iters) / 10.0;
    float b = abs(r * r - x);  // Error should be small
    
    fragColor = vec4(clamp(r, 0.0, 1.0), g, clamp(b * 10.0, 0.0, 1.0), 1.0);
}
