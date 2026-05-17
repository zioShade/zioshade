#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test wavy transformation
void main() {
    vec2 p = uv;
    
    // Wave distortion
    p.x += sin(uv.y * 10.0) * 0.05;
    p.y += cos(uv.x * 8.0) * 0.05;
    
    // Stripe pattern
    float stripe = sin(p.x * 30.0) * 0.5 + 0.5;
    
    vec3 col = mix(vec3(0.1, 0.2, 0.4), vec3(0.8, 0.6, 0.3), stripe);
    col *= 0.8 + 0.2 * sin(uv.y * 20.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
