#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test unpackHalf2x16 / packHalf2x16-like bit manipulation
void main() {
    uint packed = uint(uv.x * 65535.0);
    uint hi = packed >> 8u;
    uint lo = packed & 0xFFu;
    
    float r = float(hi) / 255.0;
    float g = float(lo) / 255.0;
    
    // Pack back
    uint repacked = (hi << 8u) | lo;
    float b = float(repacked & 0xFFFFu) / 65535.0;
    
    fragColor = vec4(r, g, b, 1.0);
}
