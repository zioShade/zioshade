#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test matrix element access patterns
void main() {
    mat3 m = mat3(
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
        7.0, 8.0, 9.0
    );
    
    // Individual element access
    float m00 = m[0][0];
    float m11 = m[1][1];
    float m22 = m[2][2];
    
    // Trace
    float trace = m00 + m11 + m22;
    
    // Modify element
    m[1][1] = trace * uv.x;
    
    vec3 result = m * vec3(uv, 0.5);
    
    fragColor = vec4(clamp(result / 15.0, 0.0, 1.0), 1.0);
}
