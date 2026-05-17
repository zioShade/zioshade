#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test concentric diamond rings
void main() {
    float x = uv.x * 6.0 - 3.0;
    float y = uv.y * 6.0 - 3.0;
    
    float diamond = abs(x) + abs(y);
    float ring1 = abs(fract(diamond * 0.4) - 0.5) * 2.0;
    float ring2 = abs(fract(diamond * 0.8 + 0.5) - 0.5) * 2.0;
    
    float pattern = min(ring1, ring2);
    
    vec3 col = vec3(pattern, pattern * 0.6, pattern * 0.3);
    col *= smoothstep(4.0, 1.0, diamond);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
