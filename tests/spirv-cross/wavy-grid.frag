#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Wavy grid deformation
void main() {
    vec2 p = uv * 6.0;
    
    // Deform the grid
    p.x += sin(p.y * 2.0) * 0.3;
    p.y += cos(p.x * 1.5) * 0.2;
    
    vec2 grid = abs(fract(p) - 0.5);
    float line = min(grid.x, grid.y);
    float col = smoothstep(0.05, 0.02, line);
    
    vec3 color = col * vec3(0.2, 0.5, 0.8);
    fragColor = vec4(color, 1.0);
}
