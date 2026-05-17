#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test op-art (optical illusion) concentric squares
void main() {
    vec2 p = uv * 10.0 - 5.0;
    
    float size_x = abs(p.x);
    float size_y = abs(p.y);
    float max_size = max(size_x, size_y);
    
    float ring = mod(floor(max_size * 2.0), 2.0);
    
    // Add rotation effect
    float angle = atan(p.y, p.x);
    float twist = sin(angle * 3.0 + max_size * 2.0) * 0.5 + 0.5;
    
    float pattern = mix(ring, twist, 0.3);
    
    vec3 col1 = vec3(0.0);
    vec3 col2 = vec3(1.0);
    vec3 col = mix(col1, col2, step(0.5, pattern));
    
    fragColor = vec4(col, 1.0);
}
