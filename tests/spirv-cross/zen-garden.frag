#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test zen garden raked sand pattern
void main() {
    vec2 p = uv * 8.0;
    
    // Concentric circles around stones
    float stone1 = length(uv - vec2(0.3, 0.4));
    float stone2 = length(uv - vec2(0.7, 0.6));
    
    // Ripple patterns
    float r1 = sin(stone1 * 50.0) * 0.5 + 0.5;
    float r2 = sin(stone2 * 50.0) * 0.5 + 0.5;
    
    // Blend between patterns
    float blend = smoothstep(0.2, 0.4, stone1) * smoothstep(0.2, 0.4, stone2);
    
    float pattern = mix(max(r1, r2), sin(p.y * 2.0) * 0.5 + 0.5, blend);
    
    // Stones
    float s1 = smoothstep(0.08, 0.07, stone1);
    float s2 = smoothstep(0.06, 0.05, stone2);
    float stones = max(s1, s2);
    
    vec3 sand = vec3(0.85, 0.78, 0.6) * (0.8 + pattern * 0.2);
    vec3 stone_col = vec3(0.3, 0.3, 0.28);
    
    vec3 col = mix(sand, stone_col, stones);
    fragColor = vec4(col, 1.0);
}
