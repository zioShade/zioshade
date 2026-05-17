#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test plasma effect with overlapping sine waves
void main() {
    float v1 = sin(uv.x * 10.0);
    float v2 = sin(uv.y * 10.0);
    float v3 = sin((uv.x + uv.y) * 10.0);
    float v4 = sin(length(uv - 0.5) * 14.0);
    
    float v = (v1 + v2 + v3 + v4) * 0.25;
    
    // Map to color
    float r = sin(v * 3.14159) * 0.5 + 0.5;
    float g = sin(v * 3.14159 + 2.094) * 0.5 + 0.5;
    float b = sin(v * 3.14159 + 4.188) * 0.5 + 0.5;
    
    // Glow at bright spots
    float glow = smoothstep(0.3, 1.0, r + g + b) * 0.5;
    
    vec3 col = vec3(r, g, b) + glow;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
