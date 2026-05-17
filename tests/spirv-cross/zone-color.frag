#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex nested conditional with mathematical operations
void main() {
    float x = uv.x * 4.0;
    float y = uv.y * 4.0;
    
    vec3 col = vec3(0.0);
    
    if (x < 1.0) {
        col = vec3(1.0, 0.0, 0.0) * sin(y * 1.57);
    } else if (x < 2.0) {
        col = vec3(0.0, 1.0, 0.0) * cos(y * 1.57);
    } else if (x < 3.0) {
        col = vec3(0.0, 0.0, 1.0) * (sin(x * 3.14) * 0.5 + 0.5);
    } else {
        col = vec3(1.0, 1.0, 0.0) * (cos(x * 3.14) * 0.5 + 0.5);
    }
    
    // Smooth transitions between zones
    float blend = fract(x) * 0.3;
    col += blend * 0.1;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
