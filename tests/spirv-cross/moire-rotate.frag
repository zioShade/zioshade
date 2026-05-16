#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Moire interference from overlapping grids
void main() {
    vec2 p = (uv - 0.5) * 20.0;
    
    // Three rotated grids
    float angle1 = 0.0;
    float angle2 = 0.15;
    float angle3 = -0.1;
    
    float c1 = cos(angle1); float s1 = sin(angle1);
    float c2 = cos(angle2); float s2 = sin(angle2);
    float c3 = cos(angle3); float s3 = sin(angle3);
    
    vec2 p1 = vec2(c1 * p.x - s1 * p.y, s1 * p.x + c1 * p.y);
    vec2 p2 = vec2(c2 * p.x - s2 * p.y, s2 * p.x + c2 * p.y);
    vec2 p3 = vec2(c3 * p.x - s3 * p.y, s3 * p.x + c3 * p.y);
    
    float g1 = sin(p1.x) * sin(p1.y);
    float g2 = sin(p2.x) * sin(p2.y);
    float g3 = sin(p3.x) * sin(p3.y);
    
    float moire = (g1 + g2 + g3) / 3.0;
    
    vec3 col = vec3(moire * 0.5 + 0.5);
    fragColor = vec4(col, 1.0);
}
