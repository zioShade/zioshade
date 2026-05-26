// Test: pack/unpack operations, bit manipulation
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Pack/unpack
    uint packed = packSnorm2x16(uv);
    vec2 unpacked = unpackSnorm2x16(packed);
    
    // Bit operations
    uint bits = floatBitsToUint(uv.x);
    uint shifted = bits << 4;
    uint masked = shifted & 0xFFFF0000u;
    uint ored = masked | 0x0000FFFFu;
    uint xored = ored ^ 0xAAAAAAAAu;
    uint inverted = ~xored;
    float result = uintBitsToFloat(inverted);
    
    // Bitfield insert/extract
    uint bf = bitfieldExtract(bits, 8, 8);
    uint bf2 = bitfieldInsert(bits, 0xFFu, 8, 8);
    
    fragColor = vec4(unpacked, result, float(bf) / 255.0);
}
