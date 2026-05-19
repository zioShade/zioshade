#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test tartan/plaid weave pattern
void main() {
    vec2 p = uv * 10.0;
    
    // Horizontal and vertical stripe sets
    float h_stripe = sin(p.x * 3.14159) * 0.5 + 0.5;
    float v_stripe = sin(p.y * 3.14159) * 0.5 + 0.5;
    
    // Multiple color bands at different widths
    float h_band1 = step(0.3, fract(p.x * 0.5)) * step(fract(p.x * 0.5), 0.7);
    float h_band2 = step(0.1, fract(p.x * 0.25)) * step(fract(p.x * 0.25), 0.4);
    
    float v_band1 = step(0.3, fract(p.y * 0.5)) * step(fract(p.y * 0.5), 0.7);
    float v_band2 = step(0.1, fract(p.y * 0.25)) * step(fract(p.y * 0.25), 0.4);
    
    // Colors
    vec3 red = vec3(0.7, 0.1, 0.1);
    vec3 dark_green = vec3(0.1, 0.35, 0.1);
    vec3 navy = vec3(0.1, 0.1, 0.35);
    vec3 gold = vec3(0.8, 0.7, 0.2);
    vec3 bg = navy;
    
    // Horizontal warp colors
    vec3 h_col = mix(dark_green, red, h_band1);
    h_col = mix(h_col, gold, h_band2 * 0.5);
    
    // Vertical weft colors
    vec3 v_col = mix(dark_green, red, v_band1);
    v_col = mix(v_col, gold, v_band2 * 0.5);
    
    // Weave blend (over-under effect)
    float h_solid = step(fract(p.y * 2.0), 0.5);
    float weave = mix(0.4, 0.6, h_solid);
    
    vec3 col = mix(h_col, v_col, weave);
    
    // Subtle texture
    float tex = fract(sin(dot(floor(uv * 200.0), vec2(12.9, 78.2))) * 43758.5) * 0.03;
    col += tex;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
