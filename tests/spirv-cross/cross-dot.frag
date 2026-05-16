#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test cross product and dot product interactions
void main() {
    vec3 a = vec3(uv.x, uv.y, 0.5);
    vec3 b = vec3(0.5, uv.x, uv.y);
    vec3 c = vec3(uv.y, 0.5, uv.x);
    
    // Cross products
    vec3 axb = cross(a, b);
    vec3 bxc = cross(b, c);
    
    // Triple product (scalar)
    float triple = dot(axb, c);
    
    // a . (b x c) should equal b . (c x a) 
    float triple2 = dot(b, cross(c, a));
    
    vec3 col = vec3(
        clamp(triple + 1.0, 0.0, 2.0) * 0.5,
        clamp(triple2 + 1.0, 0.0, 2.0) * 0.5,
        clamp(dot(a, b), 0.0, 1.0)
    );
    
    fragColor = vec4(col, 1.0);
}
