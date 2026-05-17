#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mixed integer-float expressions
void main() {
    int i = int(uv.x * 10.0);
    float f = uv.y;
    
    // int to float in expression
    float r = float(i) / 10.0;
    
    // Float comparison affecting int
    int j = int(f * 5.0);
    float g = float(j) / 5.0;
    
    // Integer arithmetic in float context
    int sum = i + j;
    int diff = i - j;
    int prod = i * max(j, 1);
    
    float b = float(sum + diff + prod) / 100.0;
    
    fragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), 1.0);
}
