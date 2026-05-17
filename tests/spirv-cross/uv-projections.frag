#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 2D texture coordinate generation
void main() {
    // Planar projection
    vec2 planar = uv;
    
    // Spherical projection
    float theta = uv.x * 6.28;
    float phi = uv.y * 3.14;
    vec3 spherical = vec3(
        sin(phi) * cos(theta),
        cos(phi),
        sin(phi) * sin(theta)
    );
    
    // Cylindrical projection
    vec2 cylindrical = vec2(
        cos(theta),
        uv.y * 2.0 - 1.0
    );
    
    // Mix projections
    vec3 col = vec3(
        length(planar - 0.5),
        spherical.x * 0.5 + 0.5,
        cylindrical.x * 0.5 + 0.5
    );
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
