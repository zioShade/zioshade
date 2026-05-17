#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple vec3 operations
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(0.3, uv.x, uv.y);
    vec3 c = vec3(0.0);
    
    // Cross product
    c = cross(a, b);
    
    // Component-wise ops
    vec3 d = abs(c);
    vec3 e = sign(c);
    vec3 f = floor(a * 3.0);
    vec3 g = fract(a * 3.0);
    vec3 h = clamp(a + b, vec3(0.0), vec3(1.0));
    vec3 i = mix(a, b, vec3(0.5));
    
    vec3 col = d * 0.2 + g * 0.3 + h * 0.2 + i * 0.3;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
