#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vec2/vec3/vec4 mixed construction
void main() {
    vec2 a = vec2(uv.x, uv.y);
    vec3 b = vec3(a, 0.5);
    vec4 c = vec4(b, 1.0);
    
    // Nested construction
    vec4 d = vec4(vec3(vec2(uv.y, uv.x), 0.3), 0.7);
    
    vec4 result = c * d;
    fragColor = vec4(clamp(result.xyz, 0.0, 1.0), 1.0);
}
