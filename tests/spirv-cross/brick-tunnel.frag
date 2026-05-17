#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test tunnel/perspective effect using polar mapping
void main() {
    vec2 p = uv - 0.5;
    
    float r = length(p) + 0.1;
    float a = atan(p.y, p.x);
    
    // Tunnel coordinates
    float tu = 1.0 / r;
    float tv = a / 6.28318 + 0.5;
    
    // Simple grid pattern in tunnel space
    float gx = fract(tu * 2.0);
    float gy = fract(tv * 8.0);
    
    float gap_x = step(0.05, gx) * step(gx, 0.95);
    float gap_y = step(0.05, gy) * step(gy, 0.95);
    float tile = gap_x * gap_y;
    
    float shade = 1.0 / (1.0 + r * 3.0);
    vec3 col = vec3(0.5, 0.3, 0.2) * tile * shade;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
