#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vec4/ivec4/uvec4 type conversions
void main() {
    vec4 fv = vec4(uv.x, uv.y, uv.x + uv.y, 1.0);
    ivec4 iv = ivec4(fv * 255.0);
    uvec4 uv4 = uvec4(iv);
    vec4 back = vec4(uv4) / 255.0;
    
    // Individual component access
    float r = back.x;
    float g = back.y;
    float b = back.z;
    
    fragColor = vec4(r, g, b, 1.0);
}
