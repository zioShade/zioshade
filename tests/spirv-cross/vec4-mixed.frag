#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vector construction from mixed scalars/vectors
void main() {
    vec2 a = vec2(uv.x, uv.y);
    float z = 0.5;
    float w = 1.0;
    
    // Mixed construction
    vec4 v = vec4(a, z, w);
    vec4 v2 = vec4(a.x, a.y, z, w);
    vec4 v3 = vec4(a, 0.5, 1.0);
    
    vec3 result = v.xyz + v2.xyz * 0.1 + v3.xyz * 0.1;
    fragColor = vec4(clamp(result, 0.0, 1.0), 1.0);
}
