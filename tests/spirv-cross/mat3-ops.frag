#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mat3 construction and operations
void main() {
    mat3 m = mat3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );
    
    // Rotation around Z
    float angle = uv.x * 6.28;
    float c = cos(angle);
    float s = sin(angle);
    mat3 rot = mat3(
        c, -s, 0.0,
        s,  c, 0.0,
        0.0, 0.0, 1.0
    );
    
    // Scale
    float scale = uv.y + 0.5;
    mat3 scl = mat3(
        scale, 0.0, 0.0,
        0.0, scale, 0.0,
        0.0, 0.0, scale
    );
    
    vec3 v = vec3(1.0, 0.0, 0.0);
    vec3 result = rot * scl * v;
    
    fragColor = vec4(result.xy * 0.5 + 0.5, result.z, 1.0);
}
