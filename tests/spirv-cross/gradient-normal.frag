#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gradient computation via finite differences
void main() {
    // Simple height field
    float f(float x, float y) {
        return sin(x * 3.0) * cos(y * 2.0) + sin(x * y * 1.5);
    }
    
    float eps = 0.01;
    float h = f(uv.x, uv.y);
    float hx = f(uv.x + eps, uv.y);
    float hy = f(uv.x, uv.y + eps);
    
    // Gradient
    float dx = (hx - h) / eps;
    float dy = (hy - h) / eps;
    
    // Normal from gradient
    vec3 normal = normalize(vec3(-dx, -dy, 1.0));
    
    // Light
    vec3 light = normalize(vec3(1.0, 1.0, 2.0));
    float diff = max(dot(normal, light), 0.0);
    
    vec3 col = vec3(0.3, 0.5, 0.2) * diff + vec3(0.05);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
