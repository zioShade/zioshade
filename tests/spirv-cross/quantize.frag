#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple in/out with different qualifiers
void main() {
    // Quantize UV
    float levels = 8.0;
    vec2 quant = floor(uv * levels) / levels;
    
    // Error diffusion pattern
    vec2 err = fract(uv * levels) - 0.5;
    float dither = err.x * err.y;
    
    // Apply dithering before quantize
    vec2 adjusted = floor((uv + dither * 0.5 / levels) * levels) / levels;
    
    vec3 col = vec3(adjusted, 0.5);
    fragColor = vec4(col, 1.0);
}
