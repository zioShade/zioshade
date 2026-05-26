// Test: integer division and modulo edge cases
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    int a = int(gl_FragCoord.x);
    int b = int(gl_FragCoord.y);
    
    // Avoid division by zero
    b = max(b, 1);
    
    int quotient = a / b;
    int remainder = a % b;
    int neg_quotient = (-a) / b;
    int neg_remainder = (-a) % b;
    
    uint ua = uint(a);
    uint ub = uint(max(b, 1));
    uint udiv = ua / ub;
    uint umod = ua % ub;
    
    fragColor = vec4(float(quotient) / 255.0, float(remainder) / 255.0, float(neg_quotient) / 255.0, float(udiv) / 255.0);
}
