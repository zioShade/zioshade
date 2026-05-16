#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Multi-layer parallax scrolling
void main() {
    vec3 col = vec3(0.0);
    
    // Layer 1: far background (slow)
    float x1 = fract(uv.x * 2.0 + 0.1);
    col += vec3(0.05, 0.05, 0.15) * step(0.5, sin(x1 * 20.0));
    
    // Layer 2: mid ground
    float x2 = fract(uv.x * 3.0 + 0.3);
    col += vec3(0.1, 0.1, 0.2) * step(0.3, sin(x2 * 15.0 + uv.y * 10.0));
    
    // Layer 3: foreground (fast)
    float x3 = fract(uv.x * 5.0 + 0.6);
    col += vec3(0.2, 0.15, 0.3) * step(0.5, sin(x3 * 25.0 + uv.y * 20.0));
    
    // Fog based on distance
    float fog = uv.y * 0.5;
    col = mix(col, vec3(0.3, 0.3, 0.4), fog);
    
    fragColor = vec4(col, 1.0);
}
