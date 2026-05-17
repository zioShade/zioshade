#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mixed scalar/vector comparisons
void main() {
    float x = uv.x;
    
    // Multiple condition levels
    int level = 0;
    if (x > 0.2) level = level + 1;
    if (x > 0.4) level = level + 1;
    if (x > 0.6) level = level + 1;
    if (x > 0.8) level = level + 1;
    
    vec3 col = vec3(0.0);
    if (level >= 1) col.r = 0.3;
    if (level >= 2) col.g = 0.3;
    if (level >= 3) col.b = 0.3;
    if (level >= 4) col = vec3(1.0);
    
    col *= 0.5 + 0.5 * sin(uv.y * 6.28);
    fragColor = vec4(col, 1.0);
}
