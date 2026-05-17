#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Barnsley fern (IFS)
void main() {
    float x = 0.0, y = 0.0;
    float sum = 0.0;
    
    for (int i = 0; i < 100; i++) {
        float r = fract(sin(float(i) * 127.1) * 43758.5);
        float nx, ny;
        
        if (r < 0.01) {
            nx = 0.0;
            ny = 0.16 * y;
        } else if (r < 0.86) {
            nx = 0.85 * x + 0.04 * y;
            ny = -0.04 * x + 0.85 * y + 1.6;
        } else if (r < 0.93) {
            nx = 0.2 * x - 0.26 * y;
            ny = 0.23 * x + 0.22 * y + 1.6;
        } else {
            nx = -0.15 * x + 0.28 * y;
            ny = 0.26 * x + 0.24 * y + 0.44;
        }
        
        x = nx;
        y = ny;
        
        // Map fern coords to UV
        vec2 fern_pos = vec2(x / 6.0 + 0.5, y / 10.0);
        sum += exp(-length(uv - fern_pos) * 200.0) * 0.15;
    }
    
    sum = min(sum, 1.0);
    vec3 col = vec3(0.1, sum * 0.8, sum * 0.3);
    fragColor = vec4(col, 1.0);
}
