#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test isometric grid projection
void main() {
    vec2 p = uv * 10.0;
    
    // Isometric transform: 30-degree angle projection
    float iso_x = (p.x - p.y) * 0.866;
    float iso_y = (p.x + p.y) * 0.5;
    
    // Grid lines in isometric space
    float grid_x = smoothstep(0.08, 0.0, abs(fract(iso_x) - 0.5));
    float grid_y = smoothstep(0.08, 0.0, abs(fract(iso_y) - 0.5));
    
    float grid = max(grid_x, grid_y);
    
    // Height map from sine waves
    vec2 ip = vec2(iso_x, iso_y);
    float h = sin(ip.x * 1.5) * cos(ip.y * 1.2) * 0.3 + 0.3;
    
    // Cell fill based on height
    vec2 cell_id = floor(ip);
    float ch = fract(sin(dot(cell_id, vec2(127.1, 311.7))) * 43758.5);
    
    // Height-based shading
    vec3 low_col = vec3(0.2, 0.5, 0.3);
    vec3 high_col = vec3(0.9, 0.85, 0.6);
    vec3 col = mix(low_col, high_col, h);
    
    // Apply grid overlay
    col = mix(col, vec3(0.1), grid * 0.7);
    
    // Elevated cells get highlight
    float elevated = smoothstep(0.4, 0.5, h);
    col += elevated * 0.15;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
