#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Simple wireframe cube illusion
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    // Fake 3D cube edges
    float edge_width = 0.03;
    
    // Top face
    float top_y = 0.3;
    float top = step(abs(p.y - top_y), edge_width) * step(p.x, 0.3) * step(-0.3, p.x);
    
    // Right face  
    float right = step(abs(p.x - 0.3), edge_width) * step(p.y, 0.3) * step(-0.3, p.y);
    
    // Bottom edge
    float bottom = step(abs(p.y + 0.3), edge_width) * step(p.x, 0.3) * step(-0.3, p.x);
    
    // Left edge
    float left = step(abs(p.x + 0.3), edge_width) * step(p.y, 0.3) * step(-0.3, p.y);
    
    float col = top + right + bottom + left;
    col = min(col, 1.0);
    
    fragColor = vec4(vec3(col * 0.8, col, col * 0.6), 1.0);
}
