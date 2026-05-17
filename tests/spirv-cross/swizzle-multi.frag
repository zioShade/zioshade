#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex swizzle patterns
void main() {
    vec4 v = vec4(uv.x, uv.y, uv.x + uv.y, uv.x - uv.y);
    
    // Multiple swizzle reads
    float a = v.x;
    vec2 b = v.yz;
    vec3 c = v.wxy;
    vec4 d = v.yzwx;
    
    // Write back via swizzle
    v.xw = vec2(a, d.w);
    
    // Read modified
    vec3 result = v.xyz + c * 0.5;
    
    fragColor = vec4(clamp(result, 0.0, 1.0), 1.0);
}
