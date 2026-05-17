#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test flag waving pattern
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Wave displacement
    float wave1 = sin(x * 8.0 + y * 2.0) * 0.03;
    float wave2 = sin(x * 12.0 - y * 3.0) * 0.02;
    float displacement = wave1 + wave2;
    
    // Distorted y for stripe pattern
    float dy = y + displacement;
    
    // Flag stripes
    float stripe = step(0.333, dy) + step(0.667, dy);
    
    vec3 colors[3];
    vec3 col;
    if (stripe < 0.5) col = vec3(0.9, 0.2, 0.2);
    else if (stripe < 1.5) col = vec3(1.0, 1.0, 1.0);
    else col = vec3(0.2, 0.2, 0.9);
    
    // Shading from wave
    float shade = 1.0 + displacement * 10.0;
    col *= shade;
    
    // Flagpole
    if (x < 0.03) col = vec3(0.4, 0.3, 0.1);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
