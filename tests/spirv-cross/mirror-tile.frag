#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mirror/tile pattern
void main() {
    // Tile UV
    vec2 tiled = fract(uv * 4.0);
    
    // Mirror every other tile
    vec2 tile_id = floor(uv * 4.0);
    if (mod(tile_id.x + tile_id.y, 2.0) > 0.5) {
        tiled = 1.0 - tiled;
    }
    
    // Circle in each tile
    float d = length(tiled - 0.5);
    float circle = smoothstep(0.35, 0.33, d);
    
    vec3 col = mix(vec3(0.1), vec3(0.6, 0.3, 0.8), circle);
    fragColor = vec4(col, 1.0);
}
