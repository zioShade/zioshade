#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test vec3 field operations
void main() {
    // Gradient field
    vec3 field = vec3(
        cos(uv.x * 5.0) * sin(uv.y * 3.0),
        sin(uv.x * 3.0) * cos(uv.y * 5.0),
        sin(uv.x * 4.0 + uv.y * 4.0)
    );
    
    // Normalize the field
    vec3 n = normalize(field + vec3(0.001));
    
    // Curl-like effect
    vec3 curl = vec3(
        field.y - field.z,
        field.z - field.x,
        field.x - field.y
    );
    curl *= 0.5;
    
    // Divergence-like
    float div = dot(n, vec3(1.0, 1.0, 1.0));
    
    vec3 col = n * 0.5 + 0.5;
    col += curl * 0.1;
    col += div * 0.2;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
