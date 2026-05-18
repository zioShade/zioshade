#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Droste/infinite zoom effect
void main() {
    vec2 p = uv - 0.5;
    
    // Log-polar transform
    float r = length(p);
    float a = atan(p.y, p.x);
    
    float log_r = log(r + 0.01);
    float scale = fract(log_r * 2.0);
    
    // Reconstruct position at different zoom
    vec2 zoomed = vec2(cos(a), sin(a)) * scale * 0.3 + 0.5;
    
    // Checkerboard pattern
    float check = mod(floor(zoomed.x * 8.0) + floor(zoomed.y * 8.0), 2.0);
    
    // Color based on zoom level
    float level = floor(log_r * 2.0);
    float hue = fract(level * 0.15);
    
    vec3 col = mix(vec3(0.2, 0.3, 0.6), vec3(0.8, 0.4, 0.2), hue) * (check * 0.5 + 0.5);
    col *= smoothstep(0.5, 0.1, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
