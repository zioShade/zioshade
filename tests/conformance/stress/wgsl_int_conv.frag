// Test: integer signedness conversions and comparisons
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    uint a = uint(gl_FragCoord.x);
    int b = int(a);
    uint c = uint(b);
    
    // Signed comparison
    int x = b - 400;
    bool neg = x < 0;
    bool pos = x > 0;
    bool zero = x == 0;
    
    float r = neg ? 1.0 : 0.0;
    float g = pos ? 1.0 : 0.0;
    float bl = zero ? 1.0 : 0.0;
    
    fragColor = vec4(r, g, bl, float(c & 255u) / 255.0);
}
