#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mixed integer/float arithmetic
void main() {
    int a = int(uv.x * 100.0);
    int b = int(uv.y * 100.0);
    
    // Integer division and modulo
    int div = a / (b + 1);
    int mod_val = a % (b + 5);
    
    // Mix with float
    float r = float(div) / 100.0;
    float g = float(mod_val) / 100.0;
    float bval = float(a + b) / 200.0;
    
    // Float from integer comparison
    float condition = (a > 50) ? 1.0 : 0.0;
    bval += condition * 0.2;
    
    fragColor = vec4(r, g, clamp(bval, 0.0, 1.0), 1.0);
}
