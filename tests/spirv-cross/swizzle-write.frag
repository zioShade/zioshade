#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test swizzle write-back (lvalue swizzle)
void main() {
    vec4 col = vec4(0.0, 0.0, 0.0, 1.0);
    
    col.x = uv.x;
    col.y = uv.y;
    col.z = (uv.x + uv.y) * 0.5;
    
    // Swizzle assignment
    col.xy = col.xy * 2.0;
    col.z = col.z - 0.5;
    
    fragColor = vec4(clamp(col.xyz, 0.0, 1.0), 1.0);
}
