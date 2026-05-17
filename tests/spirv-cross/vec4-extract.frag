#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vec4 to vec2 extraction patterns
void main() {
    vec4 a = vec4(uv.x, uv.y, uv.x * uv.y, 1.0);
    
    // Various extraction patterns
    vec2 xy = a.xy;
    vec2 yz = a.yz;
    vec2 zw = a.zw;
    vec2 wx = a.wx;
    
    // Reconstruct
    vec4 reconstructed = vec4(xy, zw);
    
    // Dot products between extracted pairs
    float d1 = dot(xy, yz);
    float d2 = dot(zw, wx);
    
    vec3 col = vec3(d1, d2, reconstructed.z);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
