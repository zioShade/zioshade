#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test honeycomb hex grid pattern
void main() {
    vec2 p = uv * 12.0;
    
    // Hex grid coordinates
    float row_h = 0.866;
    float row = floor(p.y / row_h);
    float x_offset = mod(row, 2.0) * 0.5;
    float col = floor(p.x - x_offset);
    
    vec2 fp;
    fp.y = fract(p.y / row_h);
    fp.x = fract(p.x - x_offset);
    
    // Hex distance (approximate using triangle method)
    vec2 hex_p = abs(fp - 0.5);
    float hex_d = max(hex_p.x, dot(hex_p, normalize(vec2(0.5, 0.866))));
    
    // Cell fill and edge
    float cell_fill = smoothstep(0.45, 0.42, hex_d);
    float cell_edge = smoothstep(0.42, 0.40, hex_d) * (1.0 - smoothstep(0.38, 0.36, hex_d));
    
    // Honey color per cell with depth variation
    float h = fract(sin(dot(vec2(col, row), vec2(127.1, 311.7))) * 43758.5);
    float depth = 0.5 + 0.5 * sin(h * 6.2832);
    
    vec3 honey_dark = vec3(0.6, 0.4, 0.05);
    vec3 honey_light = vec3(0.9, 0.7, 0.15);
    vec3 wax = vec3(0.85, 0.8, 0.4);
    vec3 bg = vec3(0.15, 0.12, 0.05);
    
    vec3 honey = mix(honey_dark, honey_light, depth);
    
    vec3 col = bg;
    col = mix(col, wax, cell_edge);
    col = mix(col, honey, cell_fill);
    
    // Specular highlight on honey
    float spec = exp(-dot(fp - vec2(0.35, 0.4), fp - vec2(0.35, 0.4)) * 15.0);
    col += spec * cell_fill * 0.2;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
