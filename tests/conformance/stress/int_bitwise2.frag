// Tests: integer-specific operations (bit shifts, bitwise, findLSB, findMSB)
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    int a = int(uv.x * 255.0);
    int b = int(uv.y * 255.0);
    
    // Bit shifts
    int s1 = a << 2;
    int s2 = b >> 1;
    
    // Bitwise ops
    int o1 = a | b;
    int o2 = a & 0xFF;
    int o3 = a ^ b;
    int o4 = ~a;
    
    // bitCount, bitfieldReverse
    int bc = bitCount(a);
    int br = bitfieldReverse(a);
    
    // findLSB, findMSB  
    int ls = findLSB(a);
    int ms = findMSB(a);
    
    float r = float(bc) / 8.0;
    float g = float(br & 0xFF) / 255.0;
    float bv = float(ls + ms + 14) / 28.0; // normalize to 0-1 range
    
    gl_FragColor = vec4(fract(r), fract(g), fract(bv), 1.0);
}
