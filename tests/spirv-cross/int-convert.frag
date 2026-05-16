#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test integer conversions: float→int→uint→float roundtrip
void main() {
    float f = uv.x * 100.0;
    int i = int(f);
    uint u = uint(i);
    float back = float(u);
    
    // Second path through uint first
    float f2 = uv.y * 100.0;
    uint u2 = uint(f2);
    int i2 = int(u2);
    float back2 = float(i2);
    
    float r = back / 100.0;
    float g = back2 / 100.0;
    float b = float(i & 15) / 15.0;
    
    fragColor = vec4(r, g, b, 1.0);
}
