#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test double-if pattern (diamond shape)
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    // Diamond via abs
    float diamond = abs(p.x) + abs(p.y);
    
    // Inner and outer diamond
    float inner = smoothstep(0.4, 0.35, diamond);
    float outer = smoothstep(0.8, 0.75, diamond);
    float ring = outer - inner;
    
    vec3 col = vec3(0.0);
    col += vec3(0.9, 0.3, 0.1) * inner;
    col += vec3(0.1, 0.5, 0.9) * ring;
    
    fragColor = vec4(col, 1.0);
}
