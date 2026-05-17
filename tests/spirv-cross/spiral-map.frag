#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test spiral coordinate mapping
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);
    
    // Archimedean spiral
    float spiral_r = fract((angle + 3.14159) / 0.5 + r * 2.0);
    
    // Alternating spiral arms
    float arm = mod(floor((angle + 3.14159) / 1.047), 6.0);
    float arm_color = arm / 6.0;
    
    vec3 col = vec3(spiral_r, arm_color, r);
    col *= smoothstep(1.0, 0.1, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
