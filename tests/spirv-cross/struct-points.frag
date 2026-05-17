#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test struct array pattern (using multiple structs)
struct Point {
    vec2 pos;
    vec3 color;
};

void main() {
    Point p1;
    p1.pos = vec2(0.3, 0.5);
    p1.color = vec3(1.0, 0.3, 0.1);
    
    Point p2;
    p2.pos = vec2(0.7, 0.5);
    p2.color = vec3(0.1, 0.3, 1.0);
    
    Point p3;
    p3.pos = vec2(0.5, 0.8);
    p3.color = vec3(0.1, 1.0, 0.3);
    
    float d1 = length(uv - p1.pos);
    float d2 = length(uv - p2.pos);
    float d3 = length(uv - p3.pos);
    
    vec3 col = vec3(0.02);
    col += p1.color * smoothstep(0.15, 0.0, d1);
    col += p2.color * smoothstep(0.15, 0.0, d2);
    col += p3.color * smoothstep(0.15, 0.0, d3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
