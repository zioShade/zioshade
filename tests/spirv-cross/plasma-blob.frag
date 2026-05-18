#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test plasma blob effect
void main() {
    vec2 p = uv - 0.5;
    
    // Multiple overlapping sine blobs
    float v = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        vec2 center = vec2(
            sin(fi * 1.7 + 0.5) * 0.3,
            cos(fi * 2.3 + 1.0) * 0.3
        );
        float d = length(p - center);
        v += sin(d * 12.0 - fi * 1.5) / (d + 0.3);
    }
    
    v = v * 0.3;
    
    // Map to color palette
    vec3 col;
    float t = v * 0.5 + 0.5;
    
    col.r = sin(t * 3.14159) * 0.8;
    col.g = sin(t * 3.14159 + 2.094) * 0.5 + 0.3;
    col.b = sin(t * 3.14159 + 4.188) * 0.6 + 0.4;
    
    col = clamp(col, 0.0, 1.0);
    
    // Vignette
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 1.5;
    col *= vig;
    
    fragColor = vec4(col, 1.0);
}
