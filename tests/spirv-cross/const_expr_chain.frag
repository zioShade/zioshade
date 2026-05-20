#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // Complex constant expressions
    const float pi = 3.14159265;
    const float half_pi = pi / 2.0;
    const float tau = pi * 2.0;
    const float deg_to_rad = pi / 180.0;
    
    float angle = gl_FragCoord.x * deg_to_rad;
    float r = sin(angle) * 0.5 + 0.5;
    float g = sin(angle + half_pi) * 0.5 + 0.5;
    float b = sin(angle + tau / 3.0) * 0.5 + 0.5;
    
    fragColor = vec4(r, g, b, 1.0);
}
