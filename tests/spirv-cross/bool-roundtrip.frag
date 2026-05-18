#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test various bool conversions
void main() {
    int i = int(uv.x * 10.0);
    uint u = uint(uv.y * 10.0);
    float f = uv.x * 5.0;
    
    bool b1 = bool(i);    // int → bool
    bool b2 = bool(u);    // uint → bool  
    bool b3 = bool(f);    // float → bool
    
    // Reverse: bool → int/uint/float
    int i2 = int(b1);
    uint u2 = uint(b2);
    float f2 = float(b3);
    
    float r = float(i2) / 10.0;
    float g = float(u2) / 10.0;
    float b = f2 / 5.0;
    
    fragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}
