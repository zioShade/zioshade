// Test: gradient noise with permutation table
#version 450

layout(location = 0) out vec4 fragColor;

float grad(int hash, float x, float y) {
    int h = hash & 3;
    float u = h < 2 ? x : y;
    float v = h < 2 ? y : x;
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Simple permutation-based noise
    int ix = int(floor(uv.x * 8.0));
    int iy = int(floor(uv.y * 8.0));
    
    float fx = fract(uv.x * 8.0);
    float fy = fract(uv.y * 8.0);
    
    float sx = fx * fx * (3.0 - 2.0 * fx);
    float sy = fy * fy * (3.0 - 2.0 * fy);
    
    int n00 = (ix + iy * 57) & 255;
    int n10 = (ix + 1 + iy * 57) & 255;
    int n01 = (ix + (iy + 1) * 57) & 255;
    int n11 = (ix + 1 + (iy + 1) * 57) & 255;
    
    float g00 = grad(n00, fx, fy);
    float g10 = grad(n10, fx - 1.0, fy);
    float g01 = grad(n01, fx, fy - 1.0);
    float g11 = grad(n11, fx - 1.0, fy - 1.0);
    
    float nx0 = mix(g00, g10, sx);
    float nx1 = mix(g01, g11, sx);
    float n = mix(nx0, nx1, sy);
    
    fragColor = vec4(n * 0.5 + 0.5, 0.0, 0.0, 1.0);
}
