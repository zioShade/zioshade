#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test test pattern (TV color bars) without arrays
void main() {
    float bar = floor(uv.x * 8.0);
    
    vec3 col;
    if (bar < 1.0) col = vec3(1.0, 1.0, 1.0);
    else if (bar < 2.0) col = vec3(1.0, 1.0, 0.0);
    else if (bar < 3.0) col = vec3(0.0, 1.0, 1.0);
    else if (bar < 4.0) col = vec3(0.0, 1.0, 0.0);
    else if (bar < 5.0) col = vec3(1.0, 0.0, 1.0);
    else if (bar < 6.0) col = vec3(1.0, 0.0, 0.0);
    else if (bar < 7.0) col = vec3(0.0, 0.0, 1.0);
    else col = vec3(0.0);
    
    // Bottom gradient bar
    if (uv.y < 0.25) {
        col = vec3(uv.x * 0.75 + 0.075);
    }
    
    fragColor = vec4(col, 1.0);
}
