#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test water caustics pattern
void main() {
    vec2 p = uv * 8.0;
    
    // Layered sine waves for caustic effect
    float c1 = sin(p.x * 2.0 + sin(p.y * 3.0));
    float c2 = sin(p.y * 2.5 + sin(p.x * 2.0));
    float c3 = sin((p.x + p.y) * 1.5);
    float c4 = sin((p.x - p.y) * 2.0);
    
    float caustic = (c1 + c2 + c3 + c4) * 0.25;
    caustic = pow(max(caustic, 0.0), 3.0) * 4.0;
    
    // Underwater blue tint
    vec3 water = vec3(0.1, 0.3, 0.5);
    vec3 light = vec3(0.6, 0.9, 1.0);
    
    vec3 col = water + light * caustic * 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
