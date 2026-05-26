// Test: mix of uint/int operations and comparisons
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    int signed_val = int(gl_FragCoord.x) - 400;
    uint unsigned_val = uint(gl_FragCoord.y);
    
    // Signed comparisons
    bool s_lt = signed_val < 0;
    bool s_gt = signed_val > 100;
    bool s_eq = signed_val == 0;
    
    // Unsigned comparisons
    bool u_lt = unsigned_val < 300u;
    bool u_gt = unsigned_val > 600u;
    
    // Conversion
    uint converted = uint(max(signed_val, 0));
    int back = int(converted);
    
    // Bitwise on uint
    uint masked = unsigned_val & 0xFFu;
    uint shifted_left = masked << 2;
    uint shifted_right = masked >> 1;
    
    float r = s_lt ? 1.0 : 0.0;
    float g = u_lt ? 0.5 : 0.0;
    float b = float(shifted_left & 0xFFu) / 255.0;
    
    fragColor = vec4(r, g, b, 1.0);
}
