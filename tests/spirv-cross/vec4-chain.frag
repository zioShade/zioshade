#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vec4 arithmetic chain
void main() {
    vec4 a = vec4(uv.x, uv.y, 0.0, 1.0);
    vec4 b = vec4(0.5, 0.3, uv.x, 0.0);
    vec4 c = vec4(1.0);
    
    // Chain of vec4 operations
    vec4 result = (a + b) * c - a * 0.5;
    result /= (result.w + 0.01);
    result = normalize(result);
    
    // Component-wise comparison
    vec4 mask = vec4(greaterThan(result, vec4(0.0)));
    
    vec3 col = result.xyz * 0.5 + 0.5;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
