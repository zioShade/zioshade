#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Nested ternary expressions
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Quadrant coloring using ternary chains
    vec3 col = (x > 0.5 && y > 0.5) ? vec3(1.0, 0.0, 0.0) :
               (x > 0.5 && y <= 0.5) ? vec3(0.0, 1.0, 0.0) :
               (x <= 0.5 && y > 0.5) ? vec3(0.0, 0.0, 1.0) :
               vec3(1.0, 1.0, 0.0);
    
    // Gradient within each quadrant
    float gradient = (x > 0.5) ? (y > 0.5 ? x : y) : (y > 0.5 ? y : x);
    col *= 0.5 + gradient * 0.5;
    
    fragColor = vec4(col, 1.0);
}
