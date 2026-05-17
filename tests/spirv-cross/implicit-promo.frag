#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test implicit type promotions in expressions
void main() {
    float f = uv.x;
    int i = int(uv.y * 5.0);
    
    // Float * int → float
    float r = f * float(i);
    
    // Float + int → float  
    float g = f + float(i) * 0.2;
    
    // Comparison int with float
    float b = (float(i) > f) ? 1.0 : 0.0;
    
    fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), b, 1.0);
}
