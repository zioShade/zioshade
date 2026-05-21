#version 310 es
precision highp float;
out vec4 fragColor;

// Test: integer division and modulo in expression
void main() {
    vec2 uv = gl_FragCoord.xy * 0.1;
    int x = int(uv.x);
    int y = int(uv.y);
    int quotient = x / 3;
    int remainder = x - quotient * 3;
    float val = float(quotient + remainder * y) * 0.01;
    vec3 col = vec3(val, val * 0.7, val * 1.3);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
