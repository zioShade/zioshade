#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test consecutive assignments with dependencies
void main() {
    float a = uv.x;
    float b = uv.y;
    
    a = a + b;
    b = a - b;
    a = a - b;
    
    // Now a and b are swapped
    float c = a * b;
    float d = c + a;
    float e = d - b;
    
    vec3 col = vec3(clamp(a, 0.0, 1.0), clamp(c, 0.0, 1.0), clamp(e, 0.0, 1.0));
    fragColor = vec4(col, 1.0);
}
