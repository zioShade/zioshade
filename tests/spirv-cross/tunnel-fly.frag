#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test tunnel flythrough effect
void main() {
    vec2 p = uv - 0.5;
    
    // Polar coordinates
    float r = length(p) + 0.001;
    float a = atan(p.y, p.x);
    
    // Tunnel UV
    float depth = 1.0 / r;
    float around = a / 6.28318 + 0.5;
    
    // Brick pattern in tunnel space (no conditional mutation)
    float ty = depth * 4.0;
    float tx = around * 8.0;
    float row = floor(ty);
    float offset = step(0.5, mod(row, 2.0)) * 0.5;
    vec2 brick = fract(vec2(tx + offset, ty));
    float mortar = step(0.05, brick.x) * step(brick.x, 0.95) *
                   step(0.05, brick.y) * step(brick.y, 0.95);
    
    // Lighting
    float shade = mortar * (1.0 / (1.0 + r * 8.0));
    
    vec3 col = vec3(0.5, 0.35, 0.25) * shade;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
