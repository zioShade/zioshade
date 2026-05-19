#version 430
layout(location = 0) out vec4 FragColor;

// Test sign, floor, ceil, fract, mod, abs, clamp
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    float x = uv.x * 4.0 - 2.0;
    float y = uv.y * 4.0 - 2.0;
    float r = abs(x) / 4.0;
    float g = sign(y) * 0.5 + 0.5;
    float b = fract(x * 0.5);
    float a = clamp(mod(x, 2.0) / 2.0, 0.0, 1.0);
    FragColor = vec4(r, g, b, a);
}
