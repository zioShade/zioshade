#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test basalt column joint pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 8.0;
    
    // Hex grid with offset rows
    float row_h = 0.866;
    vec2 id;
    id.y = floor(p.y / row_h);
    float x_offset = mod(id.y, 2.0) * 0.5;
    id.x = floor(p.x - x_offset);
    
    vec2 fp;
    fp.y = fract(p.y / row_h);
    fp.x = fract(p.x - x_offset);
    
    // Distance to nearest hex center
    float d = length(fp - vec2(0.5, 0.5));
    
    // Hex edge detection (approximate)
    float edge_d = max(abs(fp.x - 0.5), abs(fp.y - 0.5) * 1.15 + abs(fp.x - 0.5) * 0.3);
    
    // Column height variation
    float h = hash(id);
    float height = 0.3 + h * 0.6;
    
    // Top face
    float top = step(edge_d, 0.35) * step(uv.y, height);
    
    // Side face
    float side = step(edge_d, 0.38) * (1.0 - step(edge_d, 0.35)) * step(uv.y, height);
    
    // Joint gap
    float gap = 1.0 - step(edge_d, 0.38);
    
    vec3 stone_dark = vec3(0.25, 0.25, 0.28);
    vec3 stone_light = vec3(0.4, 0.4, 0.42);
    vec3 joint = vec3(0.1, 0.1, 0.12);
    
    vec3 col = vec3(0.05, 0.07, 0.1);
    col = mix(col, stone_light, top);
    col = mix(col, stone_dark, side);
    col = mix(col, joint, gap * step(uv.y, height + 0.05));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
