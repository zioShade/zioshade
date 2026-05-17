#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test bitwise operations on integers
void main() {
    int x = int(uv.x * 15.0);
    int y = int(uv.y * 15.0);
    
    // Bit reversal pattern
    int reversed = 0;
    for (int i = 0; i < 4; i++) {
        reversed = (reversed << 1) | ((x >> i) & 1);
    }
    
    // XOR pattern
    int xor_pattern = x ^ y;
    
    // AND mask
    int masked = x & 0x7;
    
    float r = float(reversed) / 15.0;
    float g = float(xor_pattern & 15) / 15.0;
    float b = float(masked) / 7.0;
    
    fragColor = vec4(r, g, b, 1.0);
}
