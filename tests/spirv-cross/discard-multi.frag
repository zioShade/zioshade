#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test discard with multiple conditions
void main() {
    float d1 = length(uv - vec2(0.25, 0.5));
    float d2 = length(uv - vec2(0.75, 0.5));
    float d3 = length(uv - vec2(0.5, 0.25));
    
    // Discard if outside all three circles
    if (d1 > 0.2 && d2 > 0.2 && d3 > 0.2) discard;
    
    // Color based on which circle we're in
    vec3 col = vec3(0.0);
    if (d1 < 0.2) col += vec3(1.0, 0.3, 0.1);
    if (d2 < 0.2) col += vec3(0.1, 0.5, 1.0);
    if (d3 < 0.2) col += vec3(0.2, 1.0, 0.3);
    
    fragColor = vec4(col, 1.0);
}
