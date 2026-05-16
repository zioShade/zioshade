#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Outer product / matrix construction from vectors
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(0.5, uv.x, uv.y);
    
    // Manual outer product: mat3 from vec3 x vec3
    mat3 m = mat3(
        a.x * b.x, a.x * b.y, a.x * b.z,
        a.y * b.x, a.y * b.y, a.y * b.z,
        a.z * b.x, a.z * b.y, a.z * b.z
    );
    
    // Transform a vector with the matrix
    vec3 v = vec3(1.0, 0.0, 0.0);
    vec3 result = m * v;
    
    fragColor = vec4(result * 0.5 + 0.5, 1.0);
}
