#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Cellular automaton rule 30
void main() {
    int x = int(uv.x * 64.0);
    int row = int(uv.y * 32.0);
    
    // Rule 30: left XOR (center OR right)
    uint state = 1u << 31;  // Start with single cell in center
    
    for (int r = 0; r < 32; r++) {
        if (r == row) {
            // Check if this cell is set
            uint mask = 1u << (63 - x);
            uint bit = state & mask;
            if (bit != 0u) {
                fragColor = vec4(0.9, 0.3, 0.1, 1.0);
                return;
            }
        }
        
        // Apply rule 30
        uint next = 0u;
        for (int i = 0; i < 64; i++) {
            uint left = (state >> uint(i + 1)) & 1u;
            uint center = (state >> uint(i)) & 1u;
            uint right = (state >> uint(i - 1 + 64)) & 1u;  // Wrap
            if (i == 0) right = (state >> 63u) & 1u;
            uint out_bit = left ^ (center | right);
            next |= out_bit << uint(i);
        }
        state = next;
    }
    
    fragColor = vec4(0.05, 0.05, 0.1, 1.0);
}
