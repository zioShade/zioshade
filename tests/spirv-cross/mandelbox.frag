#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Mandelbox (Mandelbulb-like 2D slice)
void main() {
    vec2 p = (uv - 0.5) * 3.0;
    vec2 z = p;
    float scale = 2.0;
    float min_r = 1e10;
    
    for (int i = 0; i < 15; i++) {
        // Box fold
        z = clamp(z, -1.0, 1.0) * 2.0 - z;
        
        // Ball fold
        float r2 = dot(z, z);
        if (r2 < 0.25) z *= 4.0;
        else if (r2 < 1.0) z *= 1.0 / r2;
        
        z = scale * z + p;
        
        float r = length(z);
        min_r = min(min_r, r);
        
        if (r > 256.0) break;
    }
    
    float col = clamp(min_r * 0.5, 0.0, 1.0);
    fragColor = vec4(col * 0.8, col * 0.4, col, 1.0);
}
