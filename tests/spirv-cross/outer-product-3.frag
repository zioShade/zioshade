#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test OpOuterProduct explicitly
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(0.5, uv.x, uv.y);
    
    // Manual outer product (3x3 matrix from vec3 x vec3)
    mat3 outer = mat3(
        a.x * b.x, a.x * b.y, a.x * b.z,
        a.y * b.x, a.y * b.y, a.y * b.z,
        a.z * b.x, a.z * b.y, a.z * b.z
    );
    
    // Apply to a vector
    vec3 v = vec3(1.0, 0.0, 0.0);
    vec3 result = outer * v;
    
    // Trace of outer product = dot(a, b)
    float trace = outer[0][0] + outer[1][1] + outer[2][2];
    float dot_ab = dot(a, b);
    
    vec3 col = result * 0.5;
    col += vec3(abs(trace - dot_ab));  // Should be ~0
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
