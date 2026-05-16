#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Brick wall pattern
void main() {
    vec2 p = uv * 8.0;
    
    // Offset every other row
    float row = floor(p.y);
    if (mod(row, 2.0) > 0.5) p.x += 0.5;
    
    vec2 brick = fract(p);
    
    // Mortar (gaps between bricks)
    float mortar_x = step(0.95, brick.x) + step(brick.x, 0.05);
    float mortar_y = step(0.9, brick.y) + step(brick.y, 0.1);
    float mortar = min(mortar_x + mortar_y, 1.0);
    
    // Brick color with variation
    float h = fract(sin(row * 127.1 + floor(p.x) * 311.7) * 43758.5);
    vec3 brick_col = vec3(0.6 + h * 0.15, 0.25 + h * 0.05, 0.15);
    vec3 mortar_col = vec3(0.7, 0.7, 0.65);
    
    vec3 col = mix(brick_col, mortar_col, mortar);
    
    fragColor = vec4(col, 1.0);
}
