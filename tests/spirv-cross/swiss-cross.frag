#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Swiss cross pattern (precision test)
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    // Square background
    float bg = step(abs(p.x), 0.8) * step(abs(p.y), 0.8);
    
    // Vertical bar of cross
    float v_bar = step(abs(p.x), 0.25) * step(abs(p.y), 0.7);
    
    // Horizontal bar of cross
    float h_bar = step(abs(p.y), 0.25) * step(abs(p.x), 0.7);
    
    float cross = max(v_bar, h_bar);
    
    vec3 col = mix(vec3(0.9, 0.1, 0.1), vec3(1.0), cross) * bg;
    
    fragColor = vec4(col, 1.0);
}
