#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Recursive tunnel effect
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    float angle = atan(p.y, p.x);
    float radius = length(p);
    
    // Infinite zoom tunnel
    float tunnel_z = 1.0 / (radius + 0.01);
    float tunnel_angle = angle / 3.14159;
    
    // Texturing the tunnel walls
    float tex_x = fract(tunnel_z * 0.5);
    float tex_y = fract(tunnel_angle);
    
    float pattern = step(0.5, fract(tex_x * 8.0)) * step(0.5, fract(tex_y * 8.0));
    
    vec3 col = mix(vec3(0.1, 0.0, 0.2), vec3(0.8, 0.6, 0.3), pattern);
    col *= smoothstep(5.0, 0.5, tunnel_z);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
