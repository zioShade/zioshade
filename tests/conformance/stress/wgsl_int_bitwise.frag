// Tests: integer bitwise operations
#version 450
uniform int u_flags;
uniform int u_mask;

void main() {
    int and_result = u_flags & u_mask;
    int or_result = u_flags | u_mask;
    int xor_result = u_flags ^ u_mask;
    int not_result = ~u_flags;
    float r = float(and_result & 0xFF) / 255.0;
    float g = float(or_result & 0xFF) / 255.0;
    float b = float(xor_result & 0xFF) / 255.0;
    gl_FragColor = vec4(r, g, b, 1.0);
}
