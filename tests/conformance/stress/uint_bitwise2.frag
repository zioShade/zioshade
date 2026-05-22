// Tests: uint bitwise operations with unsigned conversions
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    uint a = uint(uv.x * 255.0);
    uint b = uint(uv.y * 255.0);
    
    uint and_val = a & b;
    uint or_val = a | b;
    uint xor_val = a ^ b;
    uint not_val = ~a;
    uint shift = a >> 4u;
    
    float r = float(and_val) / 255.0;
    float g = float(xor_val) / 255.0;
    float b2 = float(shift) / 255.0;
    
    gl_FragColor = vec4(r, g, b2, 1.0);
}
