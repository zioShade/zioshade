#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test extract/insert on vectors
void main() {
    vec4 a = vec4(uv.x, uv.y, uv.x * uv.y, uv.x + uv.y);
    
    // Extract components
    float x = a.x;
    float y = a.y;
    float z = a.z;
    float w = a.w;
    
    // Build new vector from extracted components
    vec4 b = vec4(w, z, y, x);
    
    // Swizzle-assign
    vec3 c = b.xwy;
    
    fragColor = vec4(c, 1.0);
}
