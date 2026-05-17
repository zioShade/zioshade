#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple vec4 construction patterns
void main() {
    // Scalar construction
    vec4 a = vec4(0.5);
    
    // Mixed scalar + vec
    vec3 rgb = vec3(uv.x, uv.y, uv.x * uv.y);
    vec4 b = vec4(rgb, 1.0);
    
    // vec2 + vec2
    vec2 hi = uv;
    vec2 lo = vec2(0.5, 1.0);
    vec4 c = vec4(hi, lo);
    
    // Combine
    vec4 result = (a + b + c) / 3.0;
    
    fragColor = vec4(clamp(result.xyz, 0.0, 1.0), 1.0);
}
