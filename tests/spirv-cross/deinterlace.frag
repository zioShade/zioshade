#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test interlaced/deinterlaced pattern
void main() {
    // Even/odd scanlines
    float line_idx = floor(uv.y * 100.0);
    float is_even = 1.0 - mod(line_idx, 2.0);
    
    // Different content on even vs odd lines
    float even_val = sin(uv.x * 20.0) * 0.5 + 0.5;
    float odd_val = cos(uv.x * 15.0 + 1.0) * 0.5 + 0.5;
    
    float val = mix(odd_val, even_val, is_even);
    
    // Blend: show combined (deinterlaced) on top, interlaced on bottom
    float split = 0.5;
    vec3 col;
    if (uv.y < split) {
        // Deinterlaced: average of both
        col = vec3((even_val + odd_val) * 0.5);
    } else {
        // Interlaced: alternating lines
        col = vec3(val) * vec3(0.9, 0.95, 1.0);
    }
    
    // Divider
    float div = smoothstep(0.003, 0.0, abs(uv.y - split));
    col = mix(col, vec3(1.0, 0.5, 0.0), div);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
