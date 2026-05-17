#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test triangular mesh pattern
void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Diagonal split for triangles
    float diag = fp.x + fp.y;
    
    // Offset alternate cells
    float checker = mod(id.x + id.y, 2.0);
    
    float tri;
    if (checker > 0.5) {
        tri = step(diag, 1.0);
    } else {
        tri = step(1.0, diag);
    }
    
    float variation = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    vec3 col = tri * mix(vec3(0.3, 0.5, 0.7), vec3(0.7, 0.5, 0.3), variation);
    col += (1.0 - tri) * vec3(0.05);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
