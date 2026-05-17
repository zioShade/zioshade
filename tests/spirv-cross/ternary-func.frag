#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested ternary with function calls
float add(float a, float b) { return a + b; }
float mul(float a, float b) { return a * b; }

void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Ternary choosing which function to call
    float r = x > 0.5 ? add(x, y) : mul(x, y);
    float g = y > 0.5 ? mul(r, x) : add(r, y);
    float b = r > g ? add(g, r) : mul(g, r);
    
    fragColor = vec4(clamp(vec3(r, g, b) * 0.5, 0.0, 1.0), 1.0);
}
