#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test smoothstep edge cases
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Normal smoothstep
    float s1 = smoothstep(0.2, 0.8, x);
    
    // Reversed edges (returns complement)
    float s2 = smoothstep(0.8, 0.2, x);
    
    // Same edge (undefined but should not crash)
    float s3 = smoothstep(0.5, 0.5, x);
    
    // Smoothstep with computed edges
    float edge0 = y * 0.5;
    float edge1 = y * 0.5 + 0.5;
    float s4 = smoothstep(edge0, edge1, x);
    
    vec3 col = vec3(s1, s4, abs(s1 - s2));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
