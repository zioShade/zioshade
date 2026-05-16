#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Pixelate / mosaic effect
void main() {
    float pixel_size = 16.0;
    vec2 pixel_uv = floor(uv * pixel_size) / pixel_size;
    
    // Color based on pixelated position
    float r = sin(pixel_uv.x * 10.0) * 0.5 + 0.5;
    float g = sin(pixel_uv.y * 10.0 + 1.0) * 0.5 + 0.5;
    float b = sin((pixel_uv.x + pixel_uv.y) * 7.0 + 2.0) * 0.5 + 0.5;
    
    vec3 col = vec3(r, g, b);
    
    // Grid lines
    vec2 grid = fract(uv * pixel_size);
    float line = step(0.95, grid.x) + step(0.95, grid.y);
    col = mix(col, col * 0.7, min(line, 1.0));
    
    fragColor = vec4(col, 1.0);
}
