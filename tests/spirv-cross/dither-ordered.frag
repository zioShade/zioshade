#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Ordered dithering without gl_FragCoord
void main() {
    float val = uv.x;
    
    // Simple dithering using uv-based threshold
    vec2 cell = fract(uv * 64.0);
    float threshold = step(0.5, cell.x) + step(0.5, cell.y) * 0.5;
    threshold /= 3.0;
    
    float dithered = val > threshold ? 1.0 : 0.0;
    
    fragColor = vec4(vec3(dithered), 1.0);
}
