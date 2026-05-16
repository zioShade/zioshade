#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vector swizzle chains
void main() {
    vec4 a = vec4(uv.x, uv.y, uv.x + uv.y, uv.x * uv.y);
    
    // Chain swizzles
    vec3 b = a.wxy;     // reorder
    vec3 c = b.yzx;     // rotate
    vec2 d = c.xz;      // extract
    float e = d.y;      // single component
    
    // Multiple swizzle writes
    vec4 f = vec4(0.0);
    f.xz = d;
    f.yw = vec2(e, 1.0);
    
    fragColor = vec4(clamp(f.xyz, 0.0, 1.0), 1.0);
}
