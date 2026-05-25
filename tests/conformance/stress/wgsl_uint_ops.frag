// Tests: uint operations and conversions
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    uint a = 10u;
    uint b = 3u;
    uint sum = a + b;
    uint diff = a - b;
    uint prod = a * b;
    uint quot = a / b;
    uint mod_val = a % b;
    uint shifted = a << 2u;
    float r = float(sum) / 100.0;
    float g = float(quot) / 10.0;
    float bl = float(shifted) / 100.0;
    fragColor = vec4(r, g, bl, 1.0);
}
