#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test double helix DNA pattern
void main() {
    vec2 p = uv - vec2(0.5, 0.0);
    
    // Two interleaving sine waves
    float x1 = sin(uv.y * 12.0) * 0.15 + 0.5;
    float x2 = sin(uv.y * 12.0 + 3.14159) * 0.15 + 0.5;
    
    float d1 = abs(uv.x - x1);
    float d2 = abs(uv.x - x2);
    
    // Helix strands
    float strand1 = smoothstep(0.02, 0.008, d1);
    float strand2 = smoothstep(0.02, 0.008, d2);
    
    // Cross-links between strands (base pairs)
    float link_y = fract(uv.y * 6.0);
    float link = smoothstep(0.02, 0.01, abs(link_y - 0.5));
    float in_range = step(x2, uv.x) * step(uv.x, x1);
    float in_range2 = step(x1, uv.x) * step(uv.x, x2);
    float base_pair = link * max(in_range, in_range2);
    
    // Depth: which strand is in front
    float phase = fract(uv.y * 6.0);
    float is_front = step(0.5, phase);
    
    vec3 strand_col1 = vec3(0.3, 0.5, 0.9);
    vec3 strand_col2 = vec3(0.9, 0.4, 0.3);
    vec3 link_col = vec3(0.7, 0.7, 0.3);
    
    vec3 col = vec3(0.02);
    col += strand1 * strand_col1 * (0.3 + 0.7 * is_front);
    col += strand2 * strand_col2 * (0.3 + 0.7 * (1.0 - is_front));
    col += base_pair * link_col;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
