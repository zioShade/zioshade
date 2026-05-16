#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Sierpinski triangle via bitwise AND
void main() {
    vec2 p = uv * 256.0;
    int x = int(p.x);
    int y = int(p.y);
    
    // Sierpinski: (x & y) == 0 means inside triangle
    int sierpinski = x & y;
    float col = sierpinski == 0 ? 1.0 : 0.0;
    
    // Fade edges
    col *= step(0.0, p.x) * step(p.x, 256.0);
    col *= step(0.0, p.y) * step(p.y, 256.0);
    
    vec3 color = col * vec3(0.2, 0.6, 0.3);
    fragColor = vec4(color, 1.0);
}
