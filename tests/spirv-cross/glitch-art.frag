#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test glitch art pattern
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Channel splitting
    float offset_r = sin(y * 50.0) * 0.01 * sin(y * 3.0);
    float offset_b = sin(y * 50.0 + 2.0) * 0.01 * sin(y * 3.0 + 1.0);
    
    float r = sin((x + offset_r) * 10.0) * 0.5 + 0.5;
    float g = sin(x * 10.0) * 0.5 + 0.5;
    float b = sin((x + offset_b) * 10.0) * 0.5 + 0.5;
    
    // Scanline glitch blocks
    float block = step(0.5, fract(sin(floor(y * 20.0) * 127.1) * 43758.5));
    float glitch = block * step(0.8, fract(sin(floor(y * 20.0) * 311.7) * 43758.5));
    
    // Shift green channel on glitch
    g = mix(g, sin((x + 0.05) * 10.0) * 0.5 + 0.5, glitch);
    
    vec3 col = vec3(r, g, b);
    col *= 0.8 + 0.2 * sin(y * 200.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
