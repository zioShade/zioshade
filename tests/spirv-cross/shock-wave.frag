#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test expanding shock wave pattern
void main() {
    vec2 center = vec2(0.5, 0.5);
    float d = length(uv - center);
    
    // Multiple expanding rings
    float ring1 = abs(fract(d * 8.0 - uv.x * 2.0) - 0.5) * 2.0;
    float ring2 = abs(fract(d * 12.0 + uv.y * 1.5) - 0.5) * 2.0;
    
    // Sharpness
    float sharp1 = smoothstep(0.1, 0.05, ring1);
    float sharp2 = smoothstep(0.1, 0.05, ring2);
    
    // Fade with distance
    float fade = exp(-d * 4.0);
    
    vec3 col = vec3(0.05);
    col += sharp1 * fade * vec3(0.4, 0.7, 1.0);
    col += sharp2 * fade * vec3(1.0, 0.5, 0.3);
    
    // Center glow
    col += exp(-d * d * 30.0) * vec3(1.0, 0.9, 0.7) * 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
