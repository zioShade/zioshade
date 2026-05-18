#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test octagonal tile floor pattern
void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    
    // Octagon shape: diamond + square intersection
    float diamond = abs(fp.x - 0.5) + abs(fp.y - 0.5);
    float square = max(abs(fp.x - 0.5), abs(fp.y - 0.5));
    float octagon = smoothstep(0.4, 0.38, square) + smoothstep(0.42, 0.4, diamond);
    octagon = min(octagon, 1.0);
    
    // Grout between tiles
    float grout = 1.0 - octagon;
    
    // Tile colors
    vec3 tile_a = mix(vec3(0.6, 0.55, 0.45), vec3(0.5, 0.45, 0.35), h);
    vec3 tile_b = mix(vec3(0.35, 0.35, 0.4), vec3(0.4, 0.35, 0.3), h);
    vec3 grout_col = vec3(0.2, 0.2, 0.2);
    
    // Alternate colors
    float alt = mod(id.x + id.y, 2.0);
    vec3 tile_col = mix(tile_a, tile_b, alt);
    
    // Shading variation within tile
    float shade = 0.9 + 0.1 * smoothstep(0.3, 0.0, diamond);
    tile_col *= shade;
    
    vec3 col = mix(tile_col, grout_col, grout);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
