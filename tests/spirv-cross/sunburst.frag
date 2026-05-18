#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sunburst pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sunburst rays
    float rays = sin(a * 12.0) * 0.5 + 0.5;
    rays = pow(rays, 4.0);
    
    // Radial gradient
    float grad = 1.0 - smoothstep(0.0, 0.5, r);
    
    // Combine
    float pattern = rays * grad;
    
    // Center sun
    float sun = smoothstep(0.08, 0.05, r);
    
    vec3 ray_col = vec3(1.0, 0.8, 0.2);
    vec3 sky_col = vec3(0.2, 0.4, 0.8);
    vec3 sun_col = vec3(1.0, 0.95, 0.7);
    
    vec3 col = mix(sky_col, ray_col, pattern) + sun * sun_col;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
